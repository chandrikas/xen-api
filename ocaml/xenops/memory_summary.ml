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
open Pervasiveext

let xc = Xc.interface_open() 

let _ =

	let ( +* ) = Int64.add and ( -* ) = Int64.sub and ( /* ) = Int64.div in

	let physinfo = Xc.physinfo xc in
	let total_pages = Int64.of_nativeint physinfo.Xc.total_pages in
	let free_pages = Int64.of_nativeint physinfo.Xc.free_pages +*
		(Int64.of_nativeint physinfo.Xc.scrub_pages) in

	let domains = Xc.domain_getinfolist xc 0 in
	(* Leave out domain 0 for now *)
	let domains = List.filter (fun di -> di.Xc.domid <> 0) domains in
	let domains = List.map
		(fun di ->
			string_of_int di.Xc.domid,
			Int64.of_nativeint di.Xc.total_memory_pages
		)
		domains
	in

	Printf.printf "Total host memory: %Ld MiB\n\n" (total_pages /* 256L);

	let nhashes = 55 in
	let hashes pages =
		let n = int_of_float (Int64.to_float pages /.
			(Int64.to_float total_pages) *. (float_of_int nhashes)) in
		let hashes = String.make n '#' in
		let spaces = String.make (nhashes - n) ' ' in
		hashes ^ spaces in

	Printf.printf "%10s %s (%Ld MiB)\n" "free"
		(hashes free_pages) (free_pages /* 256L);
	List.iter
		(fun (domid, total) ->
			Printf.printf "%10s %s (%Ld MiB)\n" domid
				(hashes total) (total /* 256L)
		)
		domains
