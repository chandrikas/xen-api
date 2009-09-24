(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(* New cli talking to the in-server cli interface *)
open Stringext
open Cli_protocol

(* Need to know about the host and port to know who to connect to *)
(* Strictly, we don't need to know the username and password, but I want to be able *)
(* to make a .xe file containing defaults, so we'll pull them out of Sys.argv anyway *)

(* cmdline options override .xe options override these *)
let xapiserver = ref "127.0.0.1"
let xapiuname = ref "root"
let xapipword = ref "null"
let xapicompatmode = ref false
let xapipasswordfile = ref ""
let xapicompathost = ref "127.0.0.1"

let usessl = ref true
let xapiport = ref None 
let get_xapiport ssl =
  match !xapiport with
      None -> if ssl then 443 else 80
    | Some p -> p

let debug_enabled = ref false

let error fmt = Printf.fprintf stderr fmt
let debug fmt = Printf.kprintf (fun s -> if !debug_enabled then output_string stderr s) fmt

(* usage message *)
exception Usage

let usage () =
  if !xapicompatmode 
  then
    begin
      error "COMPATABILITY MODE\n";
      error "Usage: %s <cmd> [-h server] [-p port] ([-u username] [-pw password] or [-pwf <password file>]) <other arguments>\n" Sys.argv.(0);
      error "\nA full list of commands can be obtained by running \n\t%s help -s <server> -p <port>\n" Sys.argv.(0)
    end
  else
    begin
      error "Usage: %s <cmd> [-s server] [-p port] ([-u username] [-pw password] or [-pwf <password file>]) <other arguments>\n" Sys.argv.(0);
      error "\nA full list of commands can be obtained by running \n\t%s help -s <server> -p <port>\n" Sys.argv.(0)
    end

let is_localhost ip = ip = "127.0.0.1"

(* HTTP level bits and pieces *)

exception Http_parse_failure
let hdrs = ["content-length"; "cookie"; "connection"; "transfer-encoding"; "authorization"; "location"]
  
let end_of_string s from =
  String.sub s from ((String.length s)-from)
    
let strip_cr r =
  if String.length r=0 then raise Http_parse_failure;
  let last_char = String.sub r ((String.length r)-1) 1 in
  if last_char <> "\r" then raise Http_parse_failure;
  String.sub r 0 ((String.length r)-1)
    
let rec read_rest_of_headers ic =
  try
    let r = input_line ic in
    let r = strip_cr r in
    if r="" then [] else
      begin
	debug "read '%s'\n" r;
	let hdr = List.find (fun s -> String.startswith (s^": ") (String.lowercase r)) hdrs in
	let value = end_of_string r (String.length hdr + 2) in
	(hdr,value)::read_rest_of_headers ic
      end
  with
    | Not_found -> read_rest_of_headers ic    
    | _ -> []
	
let parse_url url =
  if String.startswith "https://" url
  then
    let stripped = end_of_string url (String.length "https://") in
    let (host::rest) = String.split '/' stripped in
    (host,"/" ^ (String.concat "/" rest))
  else
    (!xapiserver,url)


(* Read the password file *)
let read_pwf () =
  try
    let ic = open_in !xapipasswordfile in
    try
      xapiuname := (input_line ic);
      xapipword := (input_line ic)
    with End_of_file ->
      error "Error: password file format: expecting username on the first line, password on the second line\n";
      exit 1
  with
    | _ ->
	error "Error opening password file '%s'\n" !xapipasswordfile;
	exit 1
	  

let parse_port (x: string) = 
  try
    let p = int_of_string x in
    if p < 0 || p > 65535 then failwith "illegal";
    p
  with _ ->
    error "Port number must be an integer (0-65535)\n";
    raise Usage

(* Extract the arguments we're interested in. Return a list of the argumets we know *)
(* nothing about. These will get passed straight into the server *)
let parse_args args =
  
  (* Set the key to the value. Return whether the key is one we know about *)
  (* compat mode is special as the argument is passed in two places. Once  *)
  (* at the top of the message to the cli server in order to indicate that *) 
  (* we need to use 'geneva style' parsing - that is, allow key = value as *)
  (* opposed to key=value. Secondly, the key then gets passed along with   *)
  (* all the others to the operations. So we need to register it's there,  *)
  (* but not strip it                                                      *)
  let set_keyword (k,v) =
    match k with
	"server" -> xapiserver := v; true
      | "port" -> xapiport := Some (parse_port v); true 
      | "username" -> xapiuname := v; true
      | "password" -> xapipword := v; true
      | "passwordfile" -> xapipasswordfile := v; true
      | "nossl"   -> usessl := not(bool_of_string v); true
      | "compat" -> xapicompatmode := (try (bool_of_string v) with _ -> false); false (* dont strip it! *)
      | _ -> false
  in

  let rec doit args = 
    match args with
      |	"--help"::_ 
      | "-help"::_ ->
	  raise Usage
      | "-s"::server::xs ->
	  xapiserver := server;
	  doit xs
      | "-p"::port::xs ->
	  xapiport := Some (parse_port port);
	  doit xs
      | "-u"::uname::xs ->
	  xapiuname := uname;
	  doit xs
      | "-pw"::pw::xs ->
	  xapipword := pw;
	  doit xs
      | "--nossl"::xs ->
	  usessl := false;
	  doit xs
      | "-pwf"::pwf::xs ->
	  xapipasswordfile := pwf;
	  doit xs
      | "-h"::h::xs ->
	  xapicompathost := h;
	  doit xs
      | x::xs ->
	  (* we eat cmdline params if we know about them *)
	  let eatit = 
	    begin
	      try
		let eq = String.index x '=' in
		let k = String.sub x 0 eq in
		let v = String.sub x (eq+1) (String.length x - (eq+1)) in
		set_keyword (k,v)
	      with _ -> false 
	    end
	  in
	  if eatit then doit xs else x::(doit xs)
      | _ -> []
  in

  let defaults = Options.read_rc () in
  ignore (List.map set_keyword defaults); (* Defaults from the fil ~/.xe *)
  let newargs = doit args in
  (if !xapipasswordfile <> "" then read_pwf ());
  (if !xapicompatmode then xapiserver := !xapicompathost);
  newargs

let open_tcp_ssl server = 
  let port = get_xapiport true in
  debug "Connecting via stunnel to [%s] port [%d]\n%!" server port;
  (* We don't bother closing fds since this requires our close_and_exec wrapper *)
  let x = Stunnel.connect ~use_external_fd_wrapper:false 
    ~write_to_log:(fun x -> debug "stunnel: %s\n%!" x) server port in
  Unix.in_channel_of_descr x.Stunnel.fd, Unix.out_channel_of_descr x.Stunnel.fd
  (* leak the stunnel process: ok because we're short-lived *)

let open_tcp server =
    if !usessl && not(is_localhost server) then (* never use SSL on-host *)
        open_tcp_ssl server
    else (
        let host = Unix.gethostbyname server in
        let addr = host.Unix.h_addr_list.(0) in
        Unix.open_connection (Unix.ADDR_INET (addr,get_xapiport false))
    )

let open_channels () = 
    if is_localhost !xapiserver then (
      try
        Unix.open_connection (Unix.ADDR_UNIX "/var/xapi/xapi")
      with _ ->
        open_tcp !xapiserver
    ) else
      open_tcp !xapiserver


let http_response_code x = match String.split ' ' x with
  | [ _; code; _ ] -> int_of_string code
  | _ -> failwith "Bad response from HTTP server"

exception Http_failure
exception Connect_failure
exception Protocol_version_mismatch of string
exception ClientSideError of string

let attr = ref None 


let main_loop ifd ofd =
  (* Save the terminal state to restore it at exit *)
  (attr := try Some (Unix.tcgetattr Unix.stdin) with _ -> None);
  at_exit (fun () -> 
    match !attr with Some a -> Unix.tcsetattr Unix.stdin Unix.TCSANOW a | None -> ());
  (* Intially exchange version information *)
  let major', minor' = try unmarshal_protocol ifd with End_of_file -> raise Connect_failure in
  (* Be very conservative for the time-being *)
  let msg = Printf.sprintf "Server has protocol version %d.%d. Client has %d.%d" major' minor' major minor in
  debug "%s\n%!" msg;
  if major' <> major || minor' <> minor 
  then raise (Protocol_version_mismatch msg);
  marshal_protocol ofd;

  try
    while true do
      let cmd = unmarshal ifd in
      debug "Read: %s\n%!" (string_of_message cmd); flush stderr;
      match cmd with
      | Command (Print x) -> print_endline x; flush stdout
      | Command (PrintStderr x) -> Printf.fprintf stderr "%s\n%!" x
      | Command (Debug x) -> debug "debug from server: %s\n%!" x
      | Command (Load x) ->
	  begin
	    try
	      let fd = Unix.openfile x [ Unix.O_RDONLY ] 0 in
	      marshal ofd (Response OK);
	      let length = (Unix.stat x).Unix.st_size in
	      marshal ofd (Blob (Chunk (Int32.of_int length)));
	      let buffer = String.make (1024 * 1024 * 10) '\000' in
	      let left = ref length in
	      while !left > 0 do
		let n = Unix.read fd buffer 0 (min (String.length buffer) !left) in
		really_write ofd buffer 0 n;
		left := !left - n
	      done;
	      marshal ofd (Blob End);
	      Unix.close fd
	  with 
	  | e -> marshal ofd (Response Failed)
	  end
      | Command (HttpPut(filename, url)) ->
	  begin
	    try
	      let rec doit url =
		let (server,path) = parse_url url in
		if not (Sys.file_exists filename) then
			raise (ClientSideError (Printf.sprintf "file '%s' does not exist" filename));
		let fd = Unix.openfile filename [ Unix.O_RDONLY ] 0 in
		let stat = Unix.LargeFile.fstat fd in
		let ic, oc = open_tcp server in
		debug "PUTting to path [%s]\n%!" path;
		Printf.fprintf oc "PUT %s HTTP/1.0\r\ncontent-length: %Ld\r\n\r\n" path stat.Unix.LargeFile.st_size;
		flush oc;
		let resultline = input_line ic in
		(* Get the result header immediately *)
		match http_response_code resultline with
		  | 200 -> 
		      let fd' = Unix.descr_of_out_channel oc in
		      let bytes = Unixext.copy_file fd fd' in
			debug "Written %s bytes\n%!" (Int64.to_string bytes);
			Unix.close fd;
			Unix.shutdown fd' Unix.SHUTDOWN_SEND;
			marshal ofd (Response OK)
		  | 302 ->
		      let headers = read_rest_of_headers ic in
		      let newloc = List.assoc "location" headers in
		      doit newloc
		  | _ -> failwith "Unhandled response code"		    
	      in 
		doit url
	    with
	      | ClientSideError msg ->
		  marshal ofd (Response Failed);
		  Printf.fprintf stderr "Operation failed. Error: %s\n" msg;
		  exit 1		    
	      | e ->
		  debug "HttpPut failure: %s\n%!" (Printexc.to_string e);
		  (* Assume the server will figure out what's wrong and tell us over
                     the normal communication channel *)
		  marshal ofd (Response Failed) 
	  end
      | Command (HttpGet(filename, url)) ->
	  begin
	    try
	      let rec doit url =
		let (server,path) = parse_url url in
		debug "Opening connection to server '%s' path '%s'\n%!" server path;
		let ic, oc = open_tcp server in
		Printf.fprintf oc "GET %s HTTP/1.0\r\n\r\n" path;
		flush oc;
		(* Get the result header immediately *)
		let resultline = input_line ic in
		debug "Got %s\n%!" resultline;
		match http_response_code resultline with
		  | 200 -> 
		      (* Copy from channel to the file descriptor *)
		      let finished = ref false in
		      while not(!finished) do
			finished := input_line ic = "\r";
		      done;
		      let buffer = String.make 65536 '\000' in
		      let finished = ref false in
		      let fd = 
			try
		          if filename = "" then
		            Unix.dup Unix.stdout
		          else
		            Unix.openfile filename [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
		        with 
		          Unix.Unix_error (a,b,c) ->
			    (* Note that this will close the connection to the export handler, causing the task to fail *)
			    raise (ClientSideError (Printf.sprintf "%s: %s, %s." (Unix.error_message a) b c))
		      in
		      while not(!finished) do
			let num = input ic buffer 0 (String.length buffer) in
			begin try
			  really_write fd buffer 0 num;
			with
			  Unix.Unix_error (a,b,c) ->
			    raise (ClientSideError (Printf.sprintf "%s: %s, %s." (Unix.error_message a) b c))
			end;
			finished := num = 0;
		      done;
		      Unix.close fd;
		      (try close_in ic with _ -> ()); (* Nb. Unix.close_connection only requires the in_channel *)
		      marshal ofd (Response OK)
		  | 302 ->
		      let headers = read_rest_of_headers ic in
		      let newloc = List.assoc "location" headers in
		      (try close_in ic with _ -> ()); (* Nb. Unix.close_connection only requires the in_channel *)
		      doit newloc
		  | _ -> failwith "Unhandled response code"		    
	      in
	      doit url
	    with 
	      | ClientSideError msg ->
		  marshal ofd (Response Failed);
		  Printf.fprintf stderr "Operation failed. Error: %s\n" msg;
		  exit 1		    
	      | e ->
		  debug "HttpGet failure: %s\n%!" (Printexc.to_string e);
		  marshal ofd (Response Failed) 
	  end
      | Command Prompt -> 
	  let data = input_line stdin in
	  marshal ofd (Blob (Chunk (Int32.of_int (String.length data))));
	  Unix.write ofd data 0 (String.length data);
	  marshal ofd (Blob End)
      | Command (Error(code, params)) ->
	  error "Error code: %s\n" code;
	  error "Error parameters: %s\n" (String.concat ", " params)
      | Command (Exit x) -> exit x
      | x ->
	  debug "CLI protocol failure; received non-command: %s\n%!" (string_of_message x);
	  exit 1
    done
  with e ->
    debug "CLI protocol failure; caught exception: %s\n%!" (Printexc.to_string e);
    raise e
	    
let main () =
  try
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
    Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> exit 1));
    Stunnel.init_stunnel_path();
    let args = Array.to_list Sys.argv in
    let args = if List.mem "-debug" args 
      then (debug_enabled := true; List.filter (fun x -> x <> "-debug") args) 
      else args in
    if List.mem "-version" args then begin
	Printf.printf "ThinCLI protocol: %d.%d\n" major minor;
	exit 0
    end;

    if List.length args < 2 then usage () else
      begin
	let extra_args = try Sys.getenv "XE_EXTRA_ARGS" with _ -> "" in
	let split_extra = List.filter (fun s -> String.length s > 1) (String.split ',' extra_args) in    
	let cmd = List.nth args 1 in
	let args = parse_args (cmd :: split_extra @ (List.tl (List.tl args))) in
	let ic, oc = open_channels () in
	
	Printf.fprintf oc "POST /cli HTTP/1.0\r\n";
	let args = args@[("username="^ !xapiuname);("password="^ !xapipword)] in
	let args = if !xapicompatmode then "compat"::args else args in
	let args = String.concat "\n" args in
	Printf.fprintf oc "User-agent: xe-cli/Unix/%d.%d\r\n" major minor;
	Printf.fprintf oc "content-length: %d\r\n\r\n" (String.length args);
	Printf.fprintf oc "%s" args;
	flush_all ();
	
	let in_fd = Unix.descr_of_in_channel ic
	and out_fd = Unix.descr_of_out_channel oc in
	main_loop in_fd out_fd
      end
  with
    | Usage -> usage (); 
    | Not_a_cli_server ->
	error "Failed to contact a running XenServer management agent.\n";
	error "Try specifying a server name and port.\n";
	usage();
	exit 1
    | Protocol_version_mismatch x ->
	error "Protocol version mismatch: %s.\n" x;
	error "Try specifying a server name and port on the command-line.\n";
	usage();
	exit 1
    | Not_found ->
	error "Host '%s' not found.\n" !xapiserver;
	exit 1	  
    | Unix.Unix_error(err,fn,arg) as e ->
	error "Error: %s (calling %s %s)\n" (Unix.error_message err) fn arg;
	exit 1
    | Connect_failure ->
	error "Unable to contact server. Please check server and port settings.\n";
	exit 1
    | Stunnel.Stunnel_binary_missing ->
        error "Please install the stunnel package or define the XE_STUNNEL environment variable to point to the binary.\n";
	exit 1
    | End_of_file ->
	error "Lost connection to the server.\n";
	exit 1
    | e ->
	error "Unhandled exception\n%s\n" (Printexc.to_string e);
	exit 1

let _ = main ()      

    
