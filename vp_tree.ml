
module L = List

let () = Random.self_init ()

(* Vantage-point tree implementation
   Cf. "Data structures and algorithms for nearest neighbor search
   in general metric spaces" by Peter N. Yianilos for details.
   http://citeseerx.ist.psu.edu/viewdoc/\
   download?doi=10.1.1.41.4193&rep=rep1&type=pdf *)

(* Functorial interface *)

(* extend the Array module *)
module A =
struct
  include Array

  (* smaller array, without elt at index 'i' *)
  let remove i a =
    let n = length a in
    assert(i >= 0 && i < n);
    let res = make (n - 1) a.(0) in
    let j = ref 0 in
    for i' = 0 to n - 1 do
      if i' <> i then
        (unsafe_set res !j (unsafe_get a i');
         incr j)
    done;
    res

  (* <=> List.partition *)
  let partition p a =
    let ok, ko =
      fold_right (fun x (ok_acc, ko_acc) ->
          if p x then (x :: ok_acc, ko_acc)
          else (ok_acc, x :: ko_acc)
        ) a ([], [])
    in
    (of_list ok, of_list ko)

  (* <=> List.split *)
  let split a =
    let n = length a in
    if n = 0 then ([||], [||])
    else
      let l, r = a.(0) in
      let left = make n l in
      let right = make n r in
      for i = 1 to n - 1 do
        let l, r = a.(i) in
        unsafe_set left i l;
        unsafe_set right i r
      done;
      (left, right)

  (* <=> BatArray.min_max with default value in case of empty array *)
  let min_max_def a def =
    let n = length a in
    if n = 0 then def
    else
      let mini = ref a.(0) in
      let maxi = ref a.(0) in
      for i = 0 to n - 1 do
        let x = a.(i) in
        if x < !mini then
          mini := x;
        if x > !maxi then
          maxi := x
      done;
      (!mini, !maxi)

  (* get one bootstrap sample of 'size' using sampling with replacement *)
  let bootstrap_sample size a =
    let n = length a in
    assert(n > 0);
    assert(size < n);
    let res = make size a.(0) in
    for i = 1 to size do
      let rand = Random.int n in
      res.(i) <- unsafe_get a rand
    done;
    res
    
end

module type Point =
sig
  type t
  val dist: t -> t -> float
end

module Make = functor (P: Point) ->
struct

  type node = { vp: P.t;
                lb_low: float;
                lb_high: float;
                middle: float;
                rb_low: float;
                rb_high: float;
                left: t;
                right: t }
  and t = Empty
        | Node of node

  let new_node vp lb_low lb_high middle rb_low rb_high left right =
    Node { vp; lb_low; lb_high; middle; rb_low; rb_high; left; right }

  type open_itv = { lbound: float; rbound: float }

  let new_open_itv lbound rbound =
    { lbound; rbound }

  let in_open_itv x { lbound ; rbound }  =
    (x > lbound) && (x < rbound)

  let square (x: float): float =
    x *. x

  let float_compare (x: float) (y: float): int =
    if x < y then -1
    else if x > y then 1
    else 0 (* x = y *)

  let median (xs: float array): float =
    A.sort float_compare xs;
    let n = A.length xs in
    if n mod 2 = 1 then xs.(n / 2)
    else 0.5 *. (xs.(n / 2) +. xs.(n / 2 - 1))

  let variance (mu: float) (xs: float array): float =
    A.fold_left (fun acc x ->
        acc +. (square (x -. mu))
      ) 0.0 xs

  (* compute distance of point at index 'q_i' to all other points *)
  let distances (q_i: int) (points: P.t array): float array =
    let n = A.length points in
    assert(n > 1);
    let res = A.make (n - 1) 0.0 in
    let j = ref 0 in
    let q = points.(q_i) in
    for i = 0 to n - 1 do
      if i <> q_i then
        (res.(!j) <- P.dist q points.(i);
         incr j)
    done;
    res

  (* this is optimal (slowest tree construction; O(n^2));
     but fastest query time *)
  let select_best_vp (points: P.t array) =
    let n = A.length points in
    if n = 0 then assert(false)
    else if n = 1 then (points.(0), 0.0, [||])
    else
      let curr_vp = ref 0 in
      let curr_mu = ref 0.0 in
      let curr_spread = ref 0.0 in
      for i = 0 to n - 1 do
        (* could be faster using a distance cache *)
        let dists = distances !curr_vp points in
        let mu = median dists in
        let spread = variance mu dists in
        if spread > !curr_spread then
          (curr_vp := i;
           curr_mu := mu;
           curr_spread := spread)
      done;
      (points.(!curr_vp), !curr_mu, A.remove !curr_vp points)

  (* to replace select_best_vp when working with too many points *)
  let select_good_vp (points: P.t array) (sample_size: int) =
    let n = A.length points in
    if sample_size > n then
      select_best_vp points
    else
      let candidates = A.bootstrap_sample sample_size points in
      let curr_vp = ref 0 in
      let curr_mu = ref 0.0 in
      let curr_spread = ref 0.0 in
      A.iteri (fun i p_i ->
          let sample = A.bootstrap_sample sample_size points in
          let dists = A.map (P.dist p_i) sample in
          let mu = median dists in
          let spread = variance mu dists in
          if spread > !curr_spread then
            (curr_vp := i;
             curr_mu := mu;
             curr_spread := spread)
        ) candidates;
      (points.(!curr_vp), !curr_mu, A.remove !curr_vp points)

  (* to replace select_good_vp when working with way too many points,
     or if you really need the fastest possible tree construction *)
  let select_rand_vp (points: P.t array) =
    let n = A.length points in
    assert(n > 0);
    let vp = Random.int n in
    let dists = distances vp points in
    let mu = median dists in
    (points.(vp), mu, A.remove vp points)

  exception Empty_list

  let rec create' points =
    let n = A.length points in
    if n = 0 then Empty
    else if n = 1 then new_node points.(0) 0. 0. 0. 0. 0. Empty Empty
    else
      let vp, mu, others = select_best_vp points in
      let dists = A.map (fun p -> (P.dist vp p, p)) others in
      let lefties, righties = A.partition (fun (d, p) -> d < mu) dists in
      let ldists, lpoints = A.split lefties in
      let rdists, rpoints = A.split righties in
      let lb_low, lb_high = A.min_max_def ldists (0., 0.) in
      let rb_low, rb_high = A.min_max_def rdists (0., 0.) in
      let middle = (lb_high +. rb_low) *. 0.5 in
      new_node vp lb_low lb_high middle rb_low rb_high
        (create' lpoints) (create' rpoints)

  type quality = Optimal (* if you have thousands of points *)
               | Good of int (* if you have tens to hundreds
                                of thousands of points *)
               | Random (* if you have millions of points *)

  let create points =
    create' (A.of_list points)

  let rec find_nearest acc query tree =
    match tree with
    | Empty -> acc
    | Node { vp; lb_low; lb_high; middle; rb_low; rb_high; left; right } ->
      let x = P.dist vp query in
      let tau, acc' =
        match acc with
        | None -> (x, Some (x, vp))
        | Some (tau, best) ->
          if x < tau then (x, Some (x, vp))
          else (tau, Some (tau, best))
      in
      let il = new_open_itv (lb_low -. tau) (lb_high +. tau) in
      let ir = new_open_itv (rb_low -. tau) (rb_high +. tau) in
      let in_il = in_open_itv x il in
      let in_ir = in_open_itv x ir in
      if x < middle then
        match in_il, in_ir with
        | false, false -> acc'
        | true, false -> find_nearest acc' query left
        | false, true -> find_nearest acc' query right
        | true, true ->
          (match find_nearest acc' query left with
           | None -> find_nearest acc' query right
           | Some (tau, best) ->
             match find_nearest acc' query right with
             | None -> Some (tau, best)
             | Some (tau', best') ->
               if tau' < tau then Some (tau', best')
               else Some (tau, best))
      else (* x >= middle *)
        match in_ir, in_il with
        | false, false -> acc'
        | true, false -> find_nearest acc' query right
        | false, true -> find_nearest acc' query left
        | true, true ->
          (match find_nearest acc' query right with
           | None -> find_nearest acc' query left
           | Some (tau, best) ->
             match find_nearest acc' query left with
             | None -> Some (tau, best)
             | Some (tau', best') ->
               if tau' < tau then Some (tau', best')
               else Some (tau, best))

  let nearest_neighbor query tree =
    match find_nearest None query tree with
    | None -> raise Not_found
    | Some (tau, best) -> (tau, best)

  let neighbors query tol tree =
    failwith "not implemented yet"

  let rec to_list = function
    | Empty -> []
    | Node { vp; lb_low; lb_high; middle; rb_low; rb_high; left; right } ->
      let lefties = to_list left in
      let righties = to_list right in
      L.rev_append lefties (vp :: righties)

  let is_empty = function
    | Empty -> true
    | Node _ -> false

end
