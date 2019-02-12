(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*                  Fabrice Le Fessant, INRIA Saclay                   *)
(*                                                                     *)
(*  Copyright 2012 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

open Cmi_format
open Typedtree

(* Note that in Typerex, there is an awful hack to save a cmt file
   together with the interface file that was generated by ocaml (this
   is because the installed version of ocaml might differ from the one
   integrated in Typerex).
*)



let read_magic_number ic =
  let len_magic_number = String.length Config.cmt_magic_number in
  really_input_string ic len_magic_number

type binary_annots =
  | Packed of Types.signature * string list
  | Implementation of structure
  | Interface of signature
  | Partial_implementation of binary_part array
  | Partial_interface of binary_part array

and binary_part =
| Partial_structure of structure
| Partial_structure_item of structure_item
| Partial_expression of expression
| Partial_pattern of pattern
| Partial_class_expr of class_expr
| Partial_signature of signature
| Partial_signature_item of signature_item
| Partial_module_type of module_type

type cmt_infos = {
  cmt_modname : string;
  cmt_annots : binary_annots;
  cmt_value_dependencies :
    (Types.value_description * Types.value_description) list;
  cmt_comments : (string * Location.t) list;
  cmt_args : string array;
  cmt_sourcefile : string option;
  cmt_builddir : string;
  cmt_loadpath : string list;
  cmt_source_digest : Digest.t option;
  cmt_initial_env : Env.t;
  cmt_imports : (string * Digest.t option) list;
  cmt_interface_digest : Digest.t option;
  cmt_use_summaries : bool;
}

type error =
    Not_a_typedtree of string

let need_to_clear_env =
  try ignore (Sys.getenv "OCAML_BINANNOT_WITHENV"); false
  with Not_found -> true

let keep_only_summary = Env.keep_only_summary

module ClearEnv  = TypedtreeMap.MakeMap (struct
  open TypedtreeMap
  include DefaultMapArgument

  let leave_pattern p = { p with pat_env = keep_only_summary p.pat_env }
  let leave_expression e =
    let exp_extra = List.map (function
        (Texp_open (ovf, path, lloc, env), loc, attrs) ->
          (Texp_open (ovf, path, lloc, keep_only_summary env), loc, attrs)
      | exp_extra -> exp_extra) e.exp_extra in
    { e with
      exp_env = keep_only_summary e.exp_env;
      exp_extra = exp_extra }
  let leave_class_expr c =
    { c with cl_env = keep_only_summary c.cl_env }
  let leave_module_expr m =
    { m with mod_env = keep_only_summary m.mod_env }
  let leave_structure s =
    { s with str_final_env = keep_only_summary s.str_final_env }
  let leave_structure_item str =
    { str with str_env = keep_only_summary str.str_env }
  let leave_module_type m =
    { m with mty_env = keep_only_summary m.mty_env }
  let leave_signature s =
    { s with sig_final_env = keep_only_summary s.sig_final_env }
  let leave_signature_item s =
    { s with sig_env = keep_only_summary s.sig_env }
  let leave_core_type c =
    { c with ctyp_env = keep_only_summary c.ctyp_env }
  let leave_class_type c =
    { c with cltyp_env = keep_only_summary c.cltyp_env }

end)

let clear_part p = match p with
  | Partial_structure s -> Partial_structure (ClearEnv.map_structure s)
  | Partial_structure_item s ->
    Partial_structure_item (ClearEnv.map_structure_item s)
  | Partial_expression e -> Partial_expression (ClearEnv.map_expression e)
  | Partial_pattern p -> Partial_pattern (ClearEnv.map_pattern p)
  | Partial_class_expr ce -> Partial_class_expr (ClearEnv.map_class_expr ce)
  | Partial_signature s -> Partial_signature (ClearEnv.map_signature s)
  | Partial_signature_item s ->
    Partial_signature_item (ClearEnv.map_signature_item s)
  | Partial_module_type s -> Partial_module_type (ClearEnv.map_module_type s)

let clear_env binary_annots =
  if need_to_clear_env then
    match binary_annots with
      | Implementation s -> Implementation (ClearEnv.map_structure s)
      | Interface s -> Interface (ClearEnv.map_signature s)
      | Packed _ -> binary_annots
      | Partial_implementation array ->
        Partial_implementation (Array.map clear_part array)
      | Partial_interface array ->
        Partial_interface (Array.map clear_part array)

  else binary_annots




exception Error of error

let input_cmt ic = (input_value ic : cmt_infos)

let output_cmt oc cmt =
  output_string oc Config.cmt_magic_number;
  output_value oc (cmt : cmt_infos)

let read filename =
(*  Printf.fprintf stderr "Cmt_format.read %s\n%!" filename; *)
  let ic = open_in_bin filename in
  try
    let magic_number = read_magic_number ic in
    let cmi, cmt =
      if magic_number = Config.cmt_magic_number then
        None, Some (input_cmt ic)
      else if magic_number = Config.cmi_magic_number then
        let cmi = Cmi_format.input_cmi ic in
        let cmt = try
                    let magic_number = read_magic_number ic in
                    if magic_number = Config.cmt_magic_number then
                      let cmt = input_cmt ic in
                      Some cmt
                    else None
          with _ -> None
        in
        Some cmi, cmt
      else
        raise(Cmi_format.Error(Cmi_format.Not_an_interface filename))
    in
    close_in ic;
(*    Printf.fprintf stderr "Cmt_format.read done\n%!"; *)
    cmi, cmt
  with e ->
    close_in ic;
    raise e

let string_of_file filename =
  let ic = open_in filename in
  let s = Misc.string_of_file ic in
  close_in ic;
  s

let read_cmt filename =
  match read filename with
      _, None -> raise (Error (Not_a_typedtree filename))
    | _, Some cmt -> cmt

let read_cmi filename =
  match read filename with
      None, _ ->
        raise (Cmi_format.Error (Cmi_format.Not_an_interface filename))
    | Some cmi, _ -> cmi

let saved_types = ref []
let value_deps = ref []

let clear () =
  saved_types := [];
  value_deps := []

let add_saved_type b = saved_types := b :: !saved_types
let get_saved_types () = !saved_types
let set_saved_types l = saved_types := l

let record_value_dependency vd1 vd2 =
  if vd1.Types.val_loc <> vd2.Types.val_loc then
    value_deps := (vd1, vd2) :: !value_deps

let save_cmt filename modname binary_annots sourcefile initial_env sg =
  if !Clflags.binary_annotations && not !Clflags.print_types then begin
    let imports = Env.imports () in
    let oc = open_out_bin filename in
    let this_crc =
      match sg with
          None -> None
        | Some (sg) ->
          let cmi = {
            cmi_name = modname;
            cmi_sign = sg;
            cmi_flags =
            if !Clflags.recursive_types then [Cmi_format.Rectypes] else [];
            cmi_crcs = imports;
          } in
          Some (output_cmi filename oc cmi)
    in
    let source_digest = Misc.may_map Digest.file sourcefile in
    let cmt = {
      cmt_modname = modname;
      cmt_annots = clear_env binary_annots;
      cmt_value_dependencies = !value_deps;
      cmt_comments = Lexer.comments ();
      cmt_args = Sys.argv;
      cmt_sourcefile = sourcefile;
      cmt_builddir =  Sys.getcwd ();
      cmt_loadpath = !Config.load_path;
      cmt_source_digest = source_digest;
      cmt_initial_env = if need_to_clear_env then
          keep_only_summary initial_env else initial_env;
      cmt_imports = List.sort compare imports;
      cmt_interface_digest = this_crc;
      cmt_use_summaries = need_to_clear_env;
    } in
    output_cmt oc cmt;
    close_out oc;
    (* TODO: does not make sense to do post-proccesing for [Partial_implementaiton]*)
    match !Clflags.bs_gentype with
    | None -> ()
    | Some cmd -> ignore (Sys.command (cmd ^ " -cmt-add " ^ filename ^ (match sourcefile with None -> "" | Some sourcefile -> ":" ^ sourcefile)))
  end;
  clear ()
