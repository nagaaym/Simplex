open Field
open Dictionary

module Make(Field:FIELD) = struct

type t = Empty of Dictionary.t | Unbounded of Dictionary.t*int | Opt of Dictionary.t

(************* Global functions ****************)

let add_rows r1 r2 c = (* r1 <- r1 + c*r2 *)
  let _ =
    Array.fold_left
      (fun n x ->
        r1.body.(n) <- r1.body.(n) + c*x;
        n+1)
      0 r2.body in
  r1.const <- r1.const + c*r2.const

exception Found of int

let array_find arr f = (* Some n if arr.[n] is the first elt of arr that verifies f x, None otherwise *)
  try
    let _ =
      Array.fold_left
        (fun n x ->
          if f x then
            raise Found n
          else
            n+1)
        0 arr in
    None
  with Found n -> Some n

let array_doublemap arr1 arr2 ?exc:(pos=-1) f = (* arr1.(n) <- f n arr1.(n) arr2.(n), except for n *)
  assert Array.length arr1 == Array.length arr2;
  let _ =
    Array.fold_left
      (fun n x ->
        if n <> pos then
          arr1.(n) <- f arr1.(n) x
      )
      0 arr2 in
  ()

let partial_copy arr n = (* return a copy of array arr without entry n *)
  let new_arr = Array.make (Array.length arr - 1) arr.(0) in
  let (a,b) =
    Array.fold_left
      (fun (m,pos) x ->
        if n == m then
          (m+1,pos)
        else
          begin
            new_arr.(pos) <- x;
            (m+1,pos+1)
          end)
      (0,0) arr in
  assert a <> b;
  new_arr

(************* Simplex without first phase ****************)

let choose_entering dict = (* Some v if dict.vars.(v) is the entering variable, None if no entering variable *)
  array_find dict.coeffs (fun x -> F.(compare x F.zero) > 0)

let choose_leaving ent dict = (* Some v if dict.rows.(v).head is the leaving variable, None if unbounded *)
  let (_,max_var,_,denum) =
    Array.fold_left
      (fun (pos,pos_temp,num,denum) r ->
         let (num_r,denum_r) = (dict.heads.(pos),r.body.(ent)) in
         if F.(compare num_r*denum_r F.zero) < 0 && F.(compare num_r*denum denum_r*num) >= 0 then (** marche aussi pour 1st phase ?*)
           (pos+1,pos,num_r,denum_r)
         else
           (pos+1,pos_temp,num,denum))
      (0,0,F.zero,F.zero) dict.rows in
  if F.(compare denum F.zero) > 0 then
    Some max_var
  else
    None

let update_row ent lea r dict = (* row lea has been updated according to ent. now, update row r *)
  let coeff = r.body.(ent) in
      r.body.(ent) <- F.zero;
      array_doublemap r.body dict.rows.(lea).body (fun  c1 c2 -> c1 + coeff*c2 );
      r.const <- r.const + coeff*dict.rows.(lea).const

let update_dict ent lea dict = (* update all the dictionary, excepting row lea and vars *)
  array_doublemap dict.rows dict.rows ~exc:lea (fun r _ -> update_row ent lea r dict);
  update_row ent lea dict.coeffs dict

let pivot ent lea dict = (* Pivot colum ent and row lea *)
  let ent_var = dict.vars.(ent) in (* name of the entering variable *)
  let piv_row = dict.rows.(lea) in (* row to be pivot *)
  let coeff = piv_row.body.(ent) in (* coeff of the entering variable into piv_row *)
      dict.vars.(ent) <- dict.heads.(lea);
      dict.heads.(lea) <- ent_var;
      piv_row.body.(ent) <- neg F.one;
      array_doublemap piv_row piv_row (fun x _ -> x / (neg coeff));
      update_dict ent lea dict (* update the other rows + the objective *)

let rec pivots dict = (* Pivots the dictionnary until being blocked *)
  match choose_entering dict with
    | Some ent ->
        begin
          match choose_leaving ent dict with
            | Some lea ->
                pivot ent lea dict;
                pivots dict
            | None -> Unbounded (dict,ent)
        end
    | None -> Opt dict

(************* Simplex with First phase ****************)

let auxiliary_dict aux_var dict = (* Start of first phase: add an auxiliary variable, called aux_var, to the dictionnary *)
  let aux_dic =
    { vars = Array.append dict.var [|aux_var|]
    ; heads = dict.heads
    ; coeffs = Array.append (Array.make (Array.length dict.coeffs) F.zero) [|neg F.one|]
    ; rows = dict.rows
    } in
  array_doublemap aux_dic.rows aux_dic.rows (fun r _ -> Array.append r [|F.one|]);
  aux_dic

type place = Basic of int | Non_basic of int

module Vars_map = Map.Make(struct type t = var*int let compare = compare end) (* place of each variable in the initial dictionary. If v -> Basic n, then heads.(n) = v. If v -> Non_basic n then coeffs.(n) = v *)

let save_place heads_init vars_init =
  let save_basic = 
    Array.fold_left
      (fun (pos,m) v_basic ->
        (pos+1,Vars_map.add v_basic (Basic pos) m))
      (0,Vars_map.empty)
      heads_init in
  Array.fold_left
    (fun (pos',m') v_nonbasic ->
      (pos'+1,Vars_map.add v_nonbasic (Non_basic pos') m'))
    (0,save_basic)
    vars_init    

let rec project_var v coeff places coeffs_init vars_init dict =
  if coeff <> 0 then
    match find v places with
      | Non_basic pos -> dict.coeffs.body.(pos) <- coeff
      | Basic pos ->
          dict.coeffs.const <- coeffs_init.const;
          let _ = Array.fold_left
            (fun n var -> project_var var dict.rows.(pos).(n)*coeff places coeffs_init vars_init dict ; n+1) 0 vars_init in ()

let project coeffs_init heads_init vars_init aux_var dict = (* project the dictionary when the auxiliary variable is non basic *)
  let places = save_place heads_init vars_init in
  let pivot_pos = (* position of aux_var in dict.vars *)
    match array_find dict.vars (fun x -> x == aux_var) with
      | Some n -> n
      | None -> assert false in (** forcèment 0 - x0 ? *)
  let new_coeffs = { const = coeffs_init.const; body = Array.make (Array.length dict.coeffs - 1) 0 } in
  let proj_dict =
    { vars = partial_copy dict.vars pivot_pos
    ; heads = dict.heads
    ; coeffs = new_coeffs
    ; rows = array_doublemap (Array.make (Array.length dict.rows) dict.rows.(0)) dict.rows (fun _ r -> partial_copy r pivot_pos)
    } in
    let _ = Array.fold_left
      (fun n v -> project_var v coeffs_init.(n) places coeffs_init vars_init proj_dict ; n+1) 0 vars_init in ()

let first_phase dict = (* Simplex when first phase needed *)
  let coeffs_init = Array.copy dict.coeffs in (* save the coeffs for later (projection of first phase) *)
  let heads_init = Array.copy dict.heads in (* save the heads for later (projection of first phase) *)
  let vars_init = Array.copy dict.vars in (* save the vars for later (projection of first phase) *)
  let aux_var = Array.length dict.rows + Array.length dict.vars + 1 in (* name of the auxiliary variable to add *)
  let dict = auxiliary_dict aux_var dict in (* add the auxiliary variable into the dictionary *)
  match pivots dict with (* apply first phase's pivots *)
    | Opt dict | Unbounded (dict,ent) ->
        let dict_proj = project coeffs_init heads_init vars_init aux_var dict in (* projection of the dictionary, remove the auxiliary variable *)
        if F.compare(dict.coeffs.const F.zero) < 0 then
          Empty dict_proj
        else
          pivots dict_proj
    | _ -> assert false

(************* Final function ****************)

let simplex dict = (* Apply the whole simplex *)
  match array_find dict.heads (fun x -> F.(compare x F.zero) < 0) with
    | Some _ -> first_phase dict
    | None -> pivots dict

end
