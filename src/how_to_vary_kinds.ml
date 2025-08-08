open! Ppxlib
open! Stdppx
open Ast_builder.Default

module Whether_to_vary = struct
  type 'a t =
    | Vary of { kinds : expression }
    | Do_not_vary of 'a
end

type t =
  { input : core_type Whether_to_vary.t
  ; output : unit Whether_to_vary.t
  }

(* Most of the logic for building up the jkind annotations and the template attribute is
   shared between signatures and structures. [signature_item] and [structure_item] below
   just describe how to put this information (item decorations) together into a [let ...]
   or [val ...], respectively.
*)
module Item_decorations = struct
  type t =
    { input_type : core_type
    ; output_type : core_type
    ; annotations : (string loc * Ppxlib_jane.Shim.jkind_annotation option) list
    ; kind_bindings : expression
    }

  let annotation_and_template loc ~type_name ~kind_name kinds =
    let annotation =
      ( Loc.make ~loc type_name
      , Some
          ({ pjkind_loc = loc; pjkind_desc = Abbreviation kind_name }
           : Ppxlib_jane.Shim.jkind_annotation) )
    in
    let template =
      [%expr [%e pexp_ident ~loc (Loc.make ~loc (Lident kind_name))] = [%e kinds]]
    in
    annotation, template
  ;;

  let create
    { input = whether_to_vary_input; output = whether_to_vary_output }
    loc
    ~make_type_variable
    =
    let (input_type, input_kind_info), output_type_name =
      match whether_to_vary_input with
      | Do_not_vary type_ -> (type_, None), gen_symbol ~prefix:"out" ()
      | Vary { kinds } ->
        (* We don't expect this case to be used in derivers, so we can use human-readable
           names for the new-type declarations and not be worried that they are shadowing
           anything. E.g.

           {[
             type 'a b = ...

             fun (type b) -> ...
           ]}
        *)
        let input_type_name = "a" in
        let input_type = make_type_variable ~loc input_type_name in
        let input_kind_info =
          annotation_and_template loc ~type_name:input_type_name ~kind_name:"ki" kinds
        in
        (input_type, Some input_kind_info), "b"
    in
    let output_type = make_type_variable ~loc output_type_name in
    let annotations, templates =
      let annotations_and_templates =
        match whether_to_vary_output with
        | Do_not_vary () -> Option.to_list input_kind_info
        | Vary { kinds } ->
          Option.to_list input_kind_info
          @ [ annotation_and_template
                loc
                ~type_name:output_type_name
                ~kind_name:"ko"
                kinds
            ]
      in
      List.split annotations_and_templates
    in
    let kind_bindings = pexp_tuple ~loc templates in
    { input_type; output_type; annotations; kind_bindings }
  ;;
end

let base_layouts loc =
  [%expr value, immediate, immediate64, float64, bits32, bits64, word]
;;

let structure_item t loc ~function_name ~function_implementation =
  (* In the implementation, we introduce LATs, and so the inputs/outputs are syntactically
     proper type constructors (e.g. [a]) and not type variables (e.g. ['a]). *)
  let make_type_variable ~loc name = ptyp_constr ~loc (Loc.make ~loc (Lident name)) [] in
  let { input_type; output_type; annotations; kind_bindings } : Item_decorations.t =
    Item_decorations.create t loc ~make_type_variable
  in
  let f =
    Ppxlib_jane.Ast_builder.Default.add_fun_params
      ~loc
      (List.map
         annotations
         ~f:(fun (type_, kind) : Ppxlib_jane.Ast_builder.Default.function_param ->
           { pparam_loc = loc; pparam_desc = Pparam_newtype (type_, kind) }))
      (function_implementation ~input_type ~output_type)
  in
  let function_name = ppat_var ~loc (Loc.make ~loc function_name) in
  [%stri let%template [%p function_name] = [%e f] [@@kind [%e kind_bindings]]]
;;

let signature_item t loc ~function_name ~function_type =
  let { input_type; output_type; annotations; kind_bindings } : Item_decorations.t =
    Item_decorations.create t loc ~make_type_variable:ptyp_var
  in
  let input_type, input_annotations =
    match t.input with
    | Do_not_vary _ ->
      let input_type, variables_and_kinds = Common.map_type_variables input_type in
      let input_annotations =
        variables_and_kinds
        |> List.map ~f:(fun (name, jkind_annotation) ->
          Loc.make ~loc name, jkind_annotation)
      in
      input_type, input_annotations
    | Vary _ -> input_type, []
  in
  let value_descr =
    value_description
      ~loc
      ~name:(Loc.make ~loc function_name)
      ~type_:
        (function_type ~input_type ~output_type
         |> Ppxlib_jane.Ast_builder.Default.ptyp_poly
              ~loc
              (input_annotations @ annotations))
      ~prim:[]
  in
  let kind_attribute =
    attribute
      ~loc
      ~name:(Loc.make ~loc "kind")
      ~payload:(PStr [ [%stri [%e kind_bindings]] ])
  in
  let sigi =
    { value_descr with pval_attributes = kind_attribute :: value_descr.pval_attributes }
    |> psig_value ~loc
  in
  [%sigi: [%%template: [%%i sigi]]]
;;
