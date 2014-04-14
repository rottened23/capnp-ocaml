(******************************************************************************
 * capnp-ocaml
 *
 * Copyright (c) 2013-2014, Paul Pelzl
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************)


open Core.Std

module M  = Message.Make(StrStorage)
module PS = PluginSchema.Make(M)
module R  = Runtime

let sprintf = Printf.sprintf

(* Modes in which code generation can be run *)
module Mode = struct
  type t =
    | Reader
    | Builder
end


let children_of
    (nodes_table : (Uint64.t, PS.Node.t) Hashtbl.t)
    (parent : PS.Node.t)
: PS.Node.t list =
  let parent_id = PS.Node.id_get parent in
  Hashtbl.fold nodes_table ~init:[] ~f:(fun ~key:id ~data:node acc ->
    if Util.uint64_equal parent_id (PS.Node.scopeId_get node) then
      node :: acc
    else
      acc)


(* The name of a node is not encoded in that node, it is encoded in the parent.
 * So we have to implement a little search logic to get a programmatic name for
 * a node.
 *
 * Raises: Failure if we can't find the node in its parent.  (This means that capnpc
 * emitted a schema that we don't fully understand...) *)
let get_unqualified_name
    ~(parent : PS.Node.t)
    ~(child  : PS.Node.t)
: string =
  let child_id = PS.Node.id_get child in
  let nested_nodes = PS.Node.nestedNodes_get parent in
  let rec loop_nested_nodes i =
    if i = R.Array.length nested_nodes then
      None
    else
      let nested_node = R.Array.get nested_nodes i in
      if Util.uint64_equal child_id (PS.Node.NestedNode.id_get nested_node) then
        Some (PS.Node.NestedNode.name_get nested_node)
      else
        loop_nested_nodes (i + 1)
  in
  match loop_nested_nodes 0 with
  | Some s ->
      String.capitalize s
  | None ->
      let error_msg = sprintf
          "Unable to find unqualified name of child node %s (%s) \
           within parent node %s (%s)."
        (Uint64.to_string child_id)
        (PS.Node.displayName_get child)
        (Uint64.to_string (PS.Node.id_get parent))
        (PS.Node.displayName_get parent)
      in
      begin match PS.Node.unnamed_union_get parent with
      | PS.Node.File
      | PS.Node.Enum _
      | PS.Node.Interface _
      | PS.Node.Const _
      | PS.Node.Annotation _ ->
          failwith error_msg
      | PS.Node.Struct node_struct ->
          let fields = PS.Node.Struct.fields_get node_struct in
          let rec loop_fields i =
            if i = R.Array.length fields then
              failwith error_msg
            else
              let field = R.Array.get fields i in
              match PS.Field.unnamed_union_get field with
              | PS.Field.Slot _ ->
                  loop_fields (i + 1)
              | PS.Field.Group group ->
                  if Util.uint64_equal child_id
                      (PS.Field.Group.typeId_get group) then
                    String.capitalize (PS.Field.name_get field)
                  else
                    loop_fields (i + 1)
              | PS.Field.Undefined_ x ->
                  failwith (sprintf "Unknown Field union discriminant %d" x)
          in
          loop_fields 0
      | PS.Node.Undefined_ x ->
          failwith (sprintf "Unknown Node union discriminant %d" x)
      end


(* Get a representation of the fully-qualified module name for [node].
 * The resulting list associates each component of the name with the scope
 * which it defines.  The head of the list is at the outermost scope. *)
let get_fully_qualified_name_components nodes_table node
  : (string * Uint64.t) list =
  let rec loop acc curr_node =
    let scope_id = PS.Node.scopeId_get curr_node in
    if Util.uint64_equal scope_id Uint64.zero then
      acc
    else
      let parent = Hashtbl.find_exn nodes_table scope_id in
      let node_name = get_unqualified_name ~parent ~child:curr_node in
      let node_id = PS.Node.id_get curr_node in
      loop ((node_name, node_id) :: acc) parent
  in
  loop [] node


(* Get the fully-qualified name for [node]. *)
let get_fully_qualified_name nodes_table node : string =
  get_fully_qualified_name_components nodes_table node |>
  List.map ~f:fst |>
  String.concat ~sep:"."


(* Get a qualified module name for [node] which is suitable for use at the given
 * [scope_stack] position. *)
let get_scope_relative_name nodes_table (scope_stack : Uint64.t list) node
  : string =
  let rec pop_components components scope =
    match components, scope with
    | ( (component_name, component_scope_id) ::
          other_components, scope_id :: scope_ids) ->
        if Util.uint64_equal component_scope_id scope_id then
          pop_components other_components scope_ids
        else
          components
    | _ ->
        components
  in
  let fq_name = get_fully_qualified_name_components nodes_table node in
  let rel_name = pop_components fq_name (List.rev scope_stack) in
  String.concat ~sep:"." (List.map rel_name ~f:fst)


let make_unique_typename ~(mode : Mode.t) ~(scope_mode : Mode.t)
    ~nodes_table node =
  let uq_name = get_unqualified_name
    ~parent:(Hashtbl.find_exn nodes_table (PS.Node.scopeId_get node)) ~child:node
  in
  let t_str =
    if mode = Mode.Reader && scope_mode = Mode.Builder then
      "reader_t"
    else if mode = Mode.Builder && scope_mode = Mode.Reader then
      "builder_t"
    else
      "t"
  in
  sprintf "%s_%s_%s" t_str uq_name (Uint64.to_string (PS.Node.id_get node))


(* When modules refer to types defined in other modules, readability dictates that we use
 * OtherModule.t as the preferred type name.  However, consider the case of nested modules:
 *
 * module Foo = struct
 *   type t
 *   type t_FOO_UID = t
 *
 *   module Bar = struct
 *     type t
 *     type t_BAR_UID = t
 *
 *     val foo_get : t -> t_FOO_UID
 *   end
 * end
 *
 * In this case, module Foo does not have a complete declaration at the time foo_get is
 * declared.  So for this case instead of using Foo.t we emit an unambiguous type identifier
 * based on the 64-bit unique ID for Foo. *)
let make_disambiguated_type_name ~(mode : Mode.t) ~(scope_mode : Mode.t)
    ~nodes_table ~scope ~tp node =
  let node_id = PS.Node.id_get node in
  if List.mem scope node_id then
    make_unique_typename ~mode ~scope_mode ~nodes_table node
  else
    let module_name = get_scope_relative_name nodes_table scope node in
    let t_str =
      match PS.Type.unnamed_union_get tp with
      | PS.Type.Enum _ ->
          (* Enum types are identical across reader and builder, no need
             to distinguish between them *)
          ".t"
      | _ ->
          if mode = Mode.Reader && scope_mode = Mode.Builder then
            ".reader_t"
          else if mode = Mode.Builder && scope_mode = Mode.Reader then
            ".builder_t"
          else
            ".t"
    in
    module_name ^ t_str


(* Construct an ocaml name for the given schema-defined type.
   [mode] indicates whether the generated type name represents a Reader or a
   Builder type.  [scope_mode] indicates whether the generated type name is
   to be referenced within the scope of a Reader or a Builder. *)
let rec type_name ~(mode : Mode.t) ~(scope_mode : Mode.t)
    nodes_table scope tp : string =
  match PS.Type.unnamed_union_get tp with
  | PS.Type.Void    -> "unit"
  | PS.Type.Bool    -> "bool"
  | PS.Type.Int8    -> "int"
  | PS.Type.Int16   -> "int"
  | PS.Type.Int32   -> "int32"
  | PS.Type.Int64   -> "int64"
  | PS.Type.Uint8   -> "int"
  | PS.Type.Uint16  -> "int"
  | PS.Type.Uint32  -> "Uint32.t"
  | PS.Type.Uint64  -> "Uint64.t"
  | PS.Type.Float32 -> "float"
  | PS.Type.Float64 -> "float"
  | PS.Type.Text    -> "string"
  | PS.Type.Data    -> "string"
  | PS.Type.List list_descr ->
      let list_type = PS.Type.List.elementType_get list_descr in
      sprintf "(%s, array_t) Runtime.%s.t"
        (type_name ~mode ~scope_mode nodes_table scope list_type)
        (if mode = Mode.Reader then "Array" else "BArray")
  | PS.Type.Enum enum_descr ->
      let enum_id = PS.Type.Enum.typeId_get enum_descr in
      let enum_node = Hashtbl.find_exn nodes_table enum_id in
      make_disambiguated_type_name ~mode ~scope_mode ~nodes_table
        ~scope ~tp enum_node
  | PS.Type.Struct struct_descr ->
      let struct_id = PS.Type.Struct.typeId_get struct_descr in
      let struct_node = Hashtbl.find_exn nodes_table struct_id in
      make_disambiguated_type_name ~mode ~scope_mode ~nodes_table
        ~scope ~tp struct_node
  | PS.Type.Interface iface_descr ->
      let iface_id = PS.Type.Interface.typeId_get iface_descr in
      let iface_node = Hashtbl.find_exn nodes_table iface_id in
      make_disambiguated_type_name ~mode ~scope_mode ~nodes_table
        ~scope ~tp iface_node
  | PS.Type.AnyPointer ->
      "AnyPointer.t"
  | PS.Type.Undefined_ x ->
      failwith (sprintf "Unknown Type union discriminant %d" x)


(* Generate a variant type declaration for a capnp union type. *)
let generate_union_type ~(mode : Mode.t) nodes_table scope
    struct_def fields =
  let indent = String.make (2 * (List.length scope + 2)) ' ' in
  let cases = List.fold_left fields ~init:[] ~f:(fun acc field ->
    let field_name = String.capitalize (PS.Field.name_get field) in
    match PS.Field.unnamed_union_get field with
    | PS.Field.Slot slot ->
        let field_type = PS.Field.Slot.type_get slot in
        begin match PS.Type.unnamed_union_get field_type with
        | PS.Type.Void ->
            (sprintf "%s  | %s" indent field_name) :: acc
        | _ ->
            (sprintf "%s  | %s of %s" indent field_name
               (type_name ~mode ~scope_mode:mode nodes_table scope field_type))
            :: acc
        end
    | PS.Field.Group group ->
        let group_type_name =
          let group_id = PS.Field.Group.typeId_get group in
          let group_node = Hashtbl.find_exn nodes_table group_id in
          let group_module_name =
            get_scope_relative_name nodes_table scope group_node
          in
          group_module_name ^ ".t"
        in
        (sprintf "%s  | %s of %s" indent field_name group_type_name) :: acc
    | PS.Field.Undefined_ x ->
        failwith (sprintf "Unknown Field union discriminant %d" x))
  in
  let header = [
    sprintf "%stype unnamed_union_t =" indent;
  ] in
  let footer = [
    sprintf "%s  | Undefined_ of int\n" indent
  ] in
  String.concat ~sep:"\n" (header @ cases @ footer)


(* Generate the signature for an enum type. *)
let generate_enum_sig ~nodes_table ~scope ~nested_modules ~mode ~node enum_def =
  let indent = String.make (2 * (List.length scope + 2)) ' ' in
  let is_builder = mode = Mode.Builder in
  let header =
    if is_builder then
      let reader_type_string =
        "Reader." ^ (get_fully_qualified_name nodes_table node) ^ ".t"
      in
      sprintf "%stype t = %s =\n" indent reader_type_string
    else
      sprintf "%stype t =\n" indent in
  let variants =
    let enumerants = PS.Node.Enum.enumerants_get enum_def in
    let buf = Buffer.create 512 in
    for i = 0 to R.Array.length enumerants - 1 do
      let enumerant = R.Array.get enumerants i in
      let match_case =
        sprintf "%s  | %s\n"
          indent
          (String.capitalize (PS.Enumerant.name_get enumerant))
      in
      Buffer.add_string buf match_case
    done;
    let footer = sprintf "%s  | Undefined_ of int\n" indent in
    let () = Buffer.add_string buf footer in
    Buffer.contents buf
  in
  nested_modules ^ header ^ variants


let generate_constant ~nodes_table ~scope const_def =
  let const_val = PS.Node.Const.value_get const_def in
  match PS.Value.unnamed_union_get const_val with
  | PS.Value.Void ->
      "()"
  | PS.Value.Bool a ->
      if a then "true" else "false"
  | PS.Value.Int8 a
  | PS.Value.Int16 a
  | PS.Value.Uint8 a
  | PS.Value.Uint16 a ->
      Int.to_string a
  | PS.Value.Int32 a ->
      (Int32.to_string a) ^ "l"
  | PS.Value.Int64 a ->
      (Int64.to_string a) ^ "L"
  | PS.Value.Uint32 a ->
      sprintf "(Uint32.of_string %s)" (Uint32.to_string a)
  | PS.Value.Uint64 a ->
      sprintf "(Uint64.of_string %s)" (Uint64.to_string a)
  | PS.Value.Float32 a ->
      sprintf "(Int32.float_of_bits %sl)"
        (Int32.to_string (Int32.bits_of_float a))
  | PS.Value.Float64 a ->
      sprintf "(Int64.float_of_bits %sL)"
        (Int64.to_string (Int64.bits_of_float a))
  | PS.Value.Text a
  | PS.Value.Data a ->
      "\"" ^ (String.escaped a) ^ "\""
  | PS.Value.List _ ->
      failwith "List constants are not yet implemented."
  | PS.Value.Enum enum_val ->
      let const_type = PS.Node.Const.type_get const_def in
      let enum_node =
        match PS.Type.unnamed_union_get const_type with
        | PS.Type.Enum enum_def ->
            let enum_id = PS.Type.Enum.typeId_get enum_def in
            Hashtbl.find_exn nodes_table enum_id
        | _ ->
            failwith "Decoded non-enum node where enum node was expected."
      in
      let enumerants =
        match PS.Node.unnamed_union_get enum_node with
        | PS.Node.Enum enum_group -> PS.Node.Enum.enumerants_get enum_group
        | _ -> failwith "Decoded non-enum node where enum node was expected."
      in
      let scope_relative_name =
        get_scope_relative_name nodes_table scope enum_node in
      if enum_val >= R.Array.length enumerants then
        sprintf "%s.Undefined_ %u" scope_relative_name enum_val
      else
        let enumerant = R.Array.get enumerants enum_val in
        sprintf "%s.%s"
          scope_relative_name
          (String.capitalize (PS.Enumerant.name_get enumerant))
  | PS.Value.Struct _ ->
      failwith "Struct constants are not yet implemented."
  | PS.Value.Interface ->
      failwith "Interface constants are not yet implemented."
  | PS.Value.AnyPointer _ ->
      failwith "AnyPointer constants are not yet implemented."
  | PS.Value.Undefined_ x ->
      failwith (sprintf "Unknown Value union discriminant %u." x)

