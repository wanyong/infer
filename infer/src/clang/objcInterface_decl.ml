(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** In this module an ObjC interface declaration or implementation is processed. The class  *)
(** is saved in the tenv as a struct with the corresponding fields, potential superclass and *)
(** list of defined methods *)

(* ObjectiveC doesn't have a notion of static or class fields. *)
(* So, in this module we translate a class into a sil srtuct with an empty list of static fields.*)

open Utils
open CFrontend_utils

module L = Logging

let objc_class_str = "ObjC-Class"

let objc_class_annotation =
  [({ Sil.class_name = objc_class_str; Sil.parameters =[]}, true)]

let is_objc_class_annotation a =
  match a with
  | [({ Sil.class_name = n; Sil.parameters =[]}, true)] when n = objc_class_str -> true
  | _ -> false

let is_pointer_to_objc_class tenv typ =
  match typ with
  | Sil.Tptr (Sil.Tvar (Sil.TN_csu (Sil.Class, cname)), _) ->
      (match Sil.tenv_lookup tenv (Sil.TN_csu (Sil.Class, cname)) with
       | Some Sil.Tstruct(_, _, Sil.Class, _, _, _, a) when is_objc_class_annotation a -> true
       | _ -> false)
  | Sil.Tptr (Sil.Tstruct(_, _, Sil.Class, _, _, _, a), _) when
      is_objc_class_annotation a -> true
  | _ -> false

let get_super_interface_decl otdi_super =
  match otdi_super with
  | Some dr -> Ast_utils.name_opt_of_name_info_opt dr.Clang_ast_t.dr_name
  | _ -> None

let get_protocols protocols =
  let protocol_names = list_map (
      fun decl -> match decl.Clang_ast_t.dr_name with
        | Some name -> name.Clang_ast_t.ni_name
        | None -> assert false
    ) protocols in
  protocol_names

(*The superclass is the first element in the list of super classes of structs in the tenv, *)
(* then come the protocols and categories. *)
let get_interface_superclasses super_opt protocols =
  let super_class =
    match super_opt with
    | None -> []
    | Some super -> [(Sil.Class, Mangled.from_string super)] in
  let protocol_names = list_map (
      fun name -> (Sil.Protocol, Mangled.from_string name)
    ) protocols in
  let super_classes = super_class@protocol_names in
  super_classes

let create_curr_class_and_superclasses_fields tenv decl_list class_name otdi_super otdi_protocols =
  let super = get_super_interface_decl otdi_super in
  let protocols = get_protocols otdi_protocols in
  let curr_class = CContext.ContextCls (class_name, super, protocols) in
  let superclasses = get_interface_superclasses super protocols in
  let fields = CField_decl.get_fields tenv curr_class decl_list in
  curr_class, superclasses, fields

let update_curr_class curr_class superclasses =
  let get_protocols protocols = list_fold_right (
      fun protocol converted_protocols ->
        match protocol with
        | (Sil.Protocol, name) -> (Mangled.to_string name):: converted_protocols
        | _ -> converted_protocols
    ) protocols [] in
  match curr_class with
  | CContext.ContextCls (class_name, _, _) ->
      let super, protocols =
        match superclasses with
        | (Sil.Class, name):: rest -> Some (Mangled.to_string name), get_protocols rest
        | _ -> None, get_protocols superclasses in
      CContext.ContextCls (class_name, super, protocols)
  | _ -> assert false

(* Adds pairs (interface name, interface_type_info) to the global environment. *)
let add_class_to_tenv tenv decl_info class_name decl_list obj_c_interface_decl_info =
  Printing.log_out "ADDING: ObjCInterfaceDecl for '%s'\n" class_name;
  let interface_name = CTypes.mk_classname class_name in
  let curr_class, superclasses, fields =
    create_curr_class_and_superclasses_fields tenv decl_list class_name
      obj_c_interface_decl_info.Clang_ast_t.otdi_super
      obj_c_interface_decl_info.Clang_ast_t.otdi_protocols in
  let methods = ObjcProperty_decl.get_methods curr_class decl_list in
  let fields_sc = CField_decl.fields_superclass tenv obj_c_interface_decl_info in
  list_iter (fun (fn, ft, _) ->
      Printing.log_out "----->SuperClass field: '%s' " (Ident.fieldname_to_string fn);
      Printing.log_out "type: '%s'\n" (Sil.typ_to_string ft)) fields_sc;
  (*In case we found categories, or partial definition of this class earlier and they are already in the tenv *)
  let fields, superclasses, methods =
    match Sil.tenv_lookup tenv interface_name with
    | Some Sil.Tstruct(saved_fields, _, _, _, saved_superclasses, saved_methods, _) ->
        General_utils.append_no_duplicates_fields fields saved_fields,
        General_utils.append_no_duplicates_csu superclasses saved_superclasses,
        General_utils.append_no_duplicates_methods methods saved_methods
    | _ -> fields, superclasses, methods in
  let fields = General_utils.append_no_duplicates_fields fields fields_sc in
  (* We add the special hidden counter_field for implementing reference counting *)
  let fields = General_utils.append_no_duplicates_fields [Sil.objc_ref_counter_field] fields in
  let fields = General_utils.sort_fields fields in
  Printing.log_out "Class %s field:\n" class_name;
  list_iter (fun (fn, ft, _) ->
      Printing.log_out "-----> field: '%s'\n" (Ident.fieldname_to_string fn)) fields;
  let interface_type_info =
    Sil.Tstruct(fields, [], Sil.Class, Some (Mangled.from_string class_name),
                superclasses, methods, objc_class_annotation) in
  Sil.tenv_add tenv interface_name interface_type_info;
  Ast_utils.update_sil_types_map decl_info.Clang_ast_t.di_pointer (Sil.Tvar interface_name);
  Printing.log_out
    "  >>>Verifying that Typename '%s' is in tenv\n" (Sil.typename_to_string interface_name);
  (match Sil.tenv_lookup tenv interface_name with
   | Some t -> Printing.log_out "  >>>OK. Found typ='%s'\n" (Sil.typ_to_string t)
   | None -> Printing.log_out "  >>>NOT Found!!\n");
  curr_class

let add_missing_methods tenv class_name decl_list curr_class =
  let methods = ObjcProperty_decl.get_methods curr_class decl_list in
  let class_tn_name = Sil.TN_csu (Sil.Class, (Mangled.from_string class_name)) in
  match Sil.tenv_lookup tenv class_tn_name with
  | Some Sil.Tstruct(fields, [], Sil.Class, Some name, superclass, existing_methods, annotation) ->
      let methods = General_utils.append_no_duplicates_methods existing_methods methods in
      let typ = Sil.Tstruct(fields, [], Sil.Class, Some name, superclass, methods, annotation) in
      Sil.tenv_add tenv class_tn_name typ
  | _ -> ()

(* Interface_type_info has the name of instance variables and the name of methods. *)
let interface_declaration tenv decl_info class_name decl_list obj_c_interface_decl_info =
  add_class_to_tenv tenv decl_info class_name decl_list obj_c_interface_decl_info

(* Translate the methods defined in the implementation.*)
let interface_impl_declaration tenv class_name decl_list idi =
  Printing.log_out "ADDING: ObjCImplementationDecl for class '%s'\n" class_name;
  let curr_class = CContext.create_curr_class tenv class_name in
  let fields = CField_decl.get_fields tenv curr_class decl_list in
  CField_decl.add_missing_fields tenv class_name fields;
  add_missing_methods tenv class_name decl_list curr_class;
  curr_class

(* search for definition of interface with non empty set of fields that may come after their use.*)
(* Typical example: *)
(* ...Partial definition of the interface I*)
(*  :::: [later in the AST]*)
(* ...use of a field of I*)
(* ::: [later in the AST] *)
(* ...Full definition of the interface I *)
let lookup_late_defined_interface tenv cname =
  let rec scan decls =
    let open Clang_ast_t in
    match decls with
    | [] -> ()
    | ObjCInterfaceDecl (decl_info, name_info, decl_list, decl_context_info, obj_c_interface_decl_info)
      :: decls'
      when (Mangled.from_string name_info.Clang_ast_t.ni_name) = cname ->
        scan decls'
    | ObjCInterfaceDecl (decl_info, name_info, decl_list, decl_context_info, oi_decl_info)
      :: decls'
      when (Mangled.from_string name_info.Clang_ast_t.ni_name) = cname ->
        (* Assumption: here we assume that the first interface declaration with non empty set of fields is the *)
        (* correct one. So we stop. *)
        let name = name_info.Clang_ast_t.ni_name in
        ignore (interface_declaration tenv decl_info name decl_list oi_decl_info)
    | _:: decls' -> scan decls' in
  scan !CFrontend_config.global_translation_unit_decls

(* Finds the field nfield in a Tstruc. If the Tstrct is a class and the field is not found *)
(* the search is extended in a recursive way to the hierarchy of superclasses. *)
let rec find_field tenv nfield str searched_late_defined =
  (* let add_namespace_to_namefield cname =
     match namespace with
     | Some _ -> nfield
     | None -> (Mangled.to_string cname)^"_"^nfield in *)
  let print_error name_field fields =
    Printing.log_err "\nFaild to find name field '%s'\n\n" (Ident.fieldname_to_string name_field) ;
    Printing.log_err "In the following list of fields\n";
    list_iter (fun (fn, _, _) -> Printing.log_err "\nField name: '%s'\n\n" (Ident.fieldname_to_string fn)) fields;
    Printing.print_failure_info "" in
  let rec search_super s =
    match s with
    | [] -> None
    | (Sil.Class, sname):: s' ->
        Printing.log_err "@. ....Searching field in superclass (Class, '%s')@." (Mangled.to_string sname);
        let str' = Sil.tenv_lookup tenv (Sil.TN_csu(Sil.Class, sname)) in
        (match find_field tenv nfield str' searched_late_defined with
         | Some field -> Some field
         | None -> search_super s')
    | (Sil.Protocol, sname):: s' ->
        Printing.log_err "@. ... Searching field in protocol (Protocol, '%s')@." (Mangled.to_string sname);
        search_super s'
    | (Sil.Struct, sname):: s' ->
        Printing.log_err "@. ... Searching field in struct (Struct, '%s')@." (Mangled.to_string sname);
        None
    | (Sil.Union, sname):: s' ->
        Printing.log_err "@. ... Searching field in (Union, '%s')@." (Mangled.to_string sname);
        None in
  match str with
  | Some Sil.Tstruct (sf, nsf, Sil.Struct, Some cname, _, _, _)
  | Some Sil.Tstruct (sf, nsf, Sil.Union, Some cname, _, _, _) ->
      (let name_field = General_utils.mk_class_field_name (Mangled.to_string cname) nfield in
       try
         Some (list_find (fun (fn, _, _) -> Sil.fld_equal fn name_field) (sf@nsf))
       with Not_found ->
         print_error name_field (sf@nsf); None)
  | Some Sil.Tstruct (sf, nsf, Sil.Class, Some cname, super, _, _) ->
      (let name_field = General_utils.mk_class_field_name (Mangled.to_string cname) nfield in
       try
         Some (list_find (fun (fn, _, _) -> Sil.fld_equal fn name_field) (sf@nsf))
       with Not_found ->
         (* if we have already searched for late defined interfaces we check recursively *)
         (* whether the field is defined in the hiearchy of superclasses.*)
         (* If we don't find it we stop, giving error. *)
         print_error name_field (sf@nsf);
         if searched_late_defined then search_super super
         else (
           Printing.log_err "@. Search late defined...@.@.";
           (* if we don't find the field the first thing we do is scanning later definitions of interfaces. *)
           lookup_late_defined_interface tenv cname;
           let str' = Sil.tenv_lookup tenv (Sil.TN_csu(Sil.Class, cname)) in
           find_field tenv nfield str' true))
  | _ -> None
