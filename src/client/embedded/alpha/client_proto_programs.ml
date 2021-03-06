(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2017.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

module Ed25519 = Environment.Ed25519
open Client_proto_args

open Michelson_v1_printer

module Program = Client_aliases.Alias (struct
    type t = Michelson_v1_parser.parsed Micheline_parser.parsing_result
    let encoding =
      Data_encoding.conv
        (fun ({ Michelson_v1_parser.source }, _) -> source)
        (fun source -> Michelson_v1_parser.parse_toplevel source)
        Data_encoding.string
    let of_source _cctxt source =
      return (Michelson_v1_parser.parse_toplevel source)
    let to_source _ ({ Michelson_v1_parser.source }, _) = return source
    let name = "program"
  end)

let group =
  { Cli_entries.name = "programs" ;
    title = "Commands for managing the record of known programs" }

let data_parameter =
  Cli_entries.parameter (fun _ data -> return (Michelson_v1_parser.parse_expression data))

let commands () =
  let open Cli_entries in
  let show_types_switch =
    switch
      ~parameter:"-details"
      ~doc:"Show the types of each instruction" in
  let emacs_mode_switch =
    switch
      ~parameter:"-emacs"
      ~doc:"Output in michelson-mode.el compatible format" in
  let trace_stack_switch =
    switch
      ~parameter:"-trace-stack"
      ~doc:"Show the stack after each step" in
  let amount_arg =
    Client_proto_args.tez_arg
      ~parameter:"-amount"
      ~doc:"The amount of the transfer in \xEA\x9C\xA9."
      ~default:"0.05" in
  [

    command ~group ~desc: "lists all known programs"
      no_options
      (fixed [ "list" ; "known" ; "programs" ])
      (fun () cctxt ->
         Program.load cctxt >>=? fun list ->
         Lwt_list.iter_s (fun (n, _) -> cctxt.message "%s" n) list >>= fun () ->
         return ()) ;

    command ~group ~desc: "remember a program under some name"
      no_options
      (prefixes [ "remember" ; "program" ]
       @@ Program.fresh_alias_param
       @@ Program.source_param
       @@ stop)
      (fun () name program cctxt ->
         Lwt.return (Micheline_parser.no_parsing_error program) >>=? fun program ->
         Program.add cctxt name (program, [])) ;

    command ~group ~desc: "forget a remembered program"
      no_options
      (prefixes [ "forget" ; "program" ]
       @@ Program.alias_param
       @@ stop)
      (fun () (name, _) cctxt -> Program.del cctxt name) ;

    command ~group ~desc: "display a program"
      no_options
      (prefixes [ "show" ; "known" ; "program" ]
       @@ Program.alias_param
       @@ stop)
      (fun () (_, program) cctxt ->
         Lwt.return (Micheline_parser.no_parsing_error program) >>=? fun program ->
         cctxt.message "%s\n" program.source >>= fun () ->
         return ()) ;

    command ~group ~desc: "ask the node to run a program"
      (args3 trace_stack_switch amount_arg no_print_source_flag)
      (prefixes [ "run" ; "program" ]
       @@ Program.source_param
       @@ prefixes [ "on" ; "storage" ]
       @@ Cli_entries.param ~name:"storage" ~desc:"the storage data"
         data_parameter
       @@ prefixes [ "and" ; "input" ]
       @@ Cli_entries.param ~name:"storage" ~desc:"the input data"
         data_parameter
       @@ stop)
      (fun (trace_stack, amount, no_print_source) program storage input cctxt ->
         Lwt.return (Micheline_parser.no_parsing_error program) >>=? fun program ->
         Lwt.return (Micheline_parser.no_parsing_error storage) >>=? fun storage ->
         Lwt.return (Micheline_parser.no_parsing_error input) >>=? fun input ->
         let print_errors errs =
           cctxt.warning "%a"
             (Michelson_v1_error_reporter.report_errors
                ~details:false
                ~show_source: (not no_print_source)
                ~parsed: program) errs >>= fun () ->
           cctxt.error "error running program" >>= fun () ->
           return () in
         begin
           if trace_stack then
             Client_proto_rpcs.Helpers.trace_code cctxt.rpc_config
               cctxt.config.block program.expanded
               (storage.expanded, input.expanded, amount) >>=? fun (storage, output, trace) ->
             cctxt.message
               "@[<v 0>@[<v 2>storage@,%a@]@,\
                @[<v 2>output@,%a@]@,@[<v 2>trace@,%a@]@]@."
               print_expr storage
               print_expr output
               (Format.pp_print_list
                  (fun ppf (loc, gas, stack) ->
                     Format.fprintf ppf
                       "- @[<v 0>location: %d (remaining gas: %d)@,\
                        [ @[<v 0>%a ]@]@]"
                       loc gas
                       (Format.pp_print_list print_expr)
                       stack))
               trace >>= fun () ->
             return ()
           else
             Client_proto_rpcs.Helpers.run_code cctxt.rpc_config
               cctxt.config.block program.expanded
               (storage.expanded, input.expanded, amount) >>=? fun (storage, output) ->
             cctxt.message "@[<v 0>@[<v 2>storage@,%a@]@,@[<v 2>output@,%a@]@]@."
               print_expr storage
               print_expr output >>= fun () ->
             return ()
         end >>= function
         | Ok () -> return ()
         | Error errs ->
             print_errors errs);

    command ~group ~desc: "ask the node to typecheck a program"
      (args3 show_types_switch emacs_mode_switch no_print_source_flag)
      (prefixes [ "typecheck" ; "program" ]
       @@ Program.source_param
       @@ stop)
      (fun (show_types, emacs_mode, no_print_source) (program, errors) cctxt ->
         begin match errors with
           | [] ->
               Client_proto_rpcs.Helpers.typecheck_code
                 cctxt.rpc_config cctxt.config.block program.expanded
           | errors -> Lwt.return (Error errors)
         end >>= fun res ->
         if emacs_mode then
           let type_map, errs = match res with
             | Ok type_map -> type_map, []
             | Error (Environment.Ecoproto_error
                        (Script_ir_translator.Ill_typed_contract (_, type_map ) :: _)
                      :: _ as errs) ->
                 type_map, errs
             | Error errs ->
                 [], errs in
           cctxt.message
             "(@[<v 0>(types . %a)@ (errors . %a)@])"
             Michelson_v1_emacs.print_type_map (program, type_map)
             Michelson_v1_emacs.report_errors (program, errs) >>= fun () ->
           return ()
         else
           match res with
           | Ok type_map ->
               let program = inject_types type_map program in
               cctxt.message "Well typed" >>= fun () ->
               if show_types then
                 cctxt.message "%a" Micheline_printer.print_expr program >>= fun () ->
                 return ()
               else return ()
           | Error errs ->
               cctxt.warning "%a"
                 (Michelson_v1_error_reporter.report_errors
                    ~details: show_types
                    ~show_source: (not no_print_source)
                    ~parsed:program) errs >>= fun () ->
               cctxt.error "ill-typed program") ;

    command ~group ~desc: "ask the node to typecheck a data expression"
      (args1 no_print_source_flag)
      (prefixes [ "typecheck" ; "data" ]
       @@ Cli_entries.param ~name:"data" ~desc:"the data to typecheck"
         data_parameter
       @@ prefixes [ "against" ; "type" ]
       @@ Cli_entries.param ~name:"type" ~desc:"the expected type"
         data_parameter
       @@ stop)
      (fun no_print_source data exp_ty cctxt ->
         Lwt.return (Micheline_parser.no_parsing_error data) >>=? fun data ->
         Lwt.return (Micheline_parser.no_parsing_error exp_ty) >>=? fun exp_ty ->
         Client_proto_rpcs.Helpers.typecheck_data cctxt.Client_commands.rpc_config
           cctxt.config.block (data.expanded, exp_ty.expanded) >>= function
         | Ok () ->
             cctxt.message "Well typed" >>= fun () ->
             return ()
         | Error errs ->
             cctxt.warning "%a"
               (Michelson_v1_error_reporter.report_errors
                  ~details:false
                  ~show_source:(not no_print_source)
                  ?parsed:None) errs >>= fun () ->
             cctxt.error "ill-typed data") ;

    command ~group
      ~desc: "ask the node to compute the hash of a data expression \
              using the same algorithm as script instruction H"
      no_options
      (prefixes [ "hash" ; "data" ]
       @@ Cli_entries.param ~name:"data" ~desc:"the data to hash"
         data_parameter
       @@ stop)
      (fun () data cctxt ->
         Lwt.return (Micheline_parser.no_parsing_error data) >>=? fun data ->
         Client_proto_rpcs.Helpers.hash_data cctxt.Client_commands.rpc_config
           cctxt.config.block (data.expanded) >>= function
         | Ok hash ->
             cctxt.message "%S" hash >>= fun () ->
             return ()
         | Error errs ->
             cctxt.warning "%a" pp_print_error errs  >>= fun () ->
             cctxt.error "ill-formed data") ;

    command ~group
      ~desc: "ask the node to compute the hash of a data expression \
              using the same algorithm as script instruction H, sign it using \
              a given secret key, and display it using the format expected by \
              script instruction CHECK_SIGNATURE"
      no_options
      (prefixes [ "hash" ; "and" ; "sign" ; "data" ]
       @@ Cli_entries.param ~name:"data" ~desc:"the data to hash"
         data_parameter
       @@ prefixes [ "for" ]
       @@ Client_keys.Secret_key.alias_param
       @@ stop)
      (fun () data (_, key) cctxt ->
         Lwt.return (Micheline_parser.no_parsing_error data) >>=? fun data ->
         Client_proto_rpcs.Helpers.hash_data cctxt.rpc_config
           cctxt.config.block (data.expanded) >>= function
         | Ok hash ->
             let signature = Ed25519.sign key (MBytes.of_string hash) in
             cctxt.message "Hash: %S@.Signature: %S"
               hash
               (signature |>
                Data_encoding.Binary.to_bytes Ed25519.Signature.encoding |>
                Hex_encode.hex_of_bytes) >>= fun () ->
             return ()
         | Error errs ->
             cctxt.warning "%a" pp_print_error errs >>= fun () ->
             cctxt.error "ill-formed data") ;

  ]
