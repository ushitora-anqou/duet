open BatPervasives

include Log.Make(struct let name = "srk.polynomial" end)

module type Univariate = sig
  include Ring.Vector with type dim = int
  val order : t -> int
  val mul : t -> t -> t
  val one : t
  val scalar : scalar -> t
  val compose : t -> t -> t
  val identity : t
  val eval : t -> scalar -> scalar
  val exp : t -> int -> t
  val mul_monomial : scalar -> int -> t -> t
end

module MakeUnivariate(R : Algebra.Ring) = struct
  include Ring.RingMap(SrkUtil.Int)(R)

  let order p = fold (fun power _ hi -> max hi power) p 0

  let scalar k = of_term k 0

  let one = scalar R.one

  let identity = of_term R.one 1

  let mul_monomial coeff power p =
    (enum p)
    /@ (fun (coeff',power') -> (R.mul coeff coeff', power * power'))
    |> of_enum

  let mul p q =
    BatEnum.fold
      (fun r ((pc,pp), (qc,qp)) -> add_term (R.mul pc qc) (pp + qp) r)
      zero
      (SrkUtil.cartesian_product (enum p) (enum q))

  let exp = SrkUtil.exp mul one

  let compose p q =
    let rec go n = function
      | [] -> zero
      | (coeff,k)::xs ->
        let multiplier = exp q (k-n) in
        mul multiplier (add_term coeff 0 (go k xs))
    in
    enum p
    |> BatList.of_enum
    |> BatList.sort (fun x y -> Stdlib.compare (snd x) (snd y))
    |> go 0

  let scalar k = add_term k 0 zero

  let eval p k = fst (pivot 0 (compose p (scalar k)))
end

module QQX = struct
  include MakeUnivariate(QQ)

  let pp formatter p =
    let pp_monomial formatter (coeff, order) =
      if order = 0 then
        QQ.pp formatter coeff
      else if QQ.equal coeff QQ.one then
        Format.fprintf formatter "@[x^%d@]" order
      else if QQ.equal coeff (QQ.negate QQ.one) then
        Format.fprintf formatter "@[-x^%d@]" order
      else
        Format.fprintf formatter "@[%a*x^%d@]" QQ.pp coeff order
    in
    SrkUtil.pp_print_enum
      ~pp_sep:(fun formatter () -> Format.fprintf formatter "@ + ")
      pp_monomial
      formatter
      (enum p)

  let show = SrkUtil.mk_show pp

  let summation p =
    let module M = Linear.QQMatrix in
    let module V = Linear.QQVector in
    let sum_order = (order p) + 1 in
    assert (sum_order > 0);
    (* Create a system of linear equalities:
           c_n*0^n + ... + c_1*0 + c_0 = p(0)
           c_n*1^n + ... + c_1*1 + c_0 = p(0) + p(1)
           c_n*2^n + ... + c_1*2 + c_0 = p(0) + p(1) + p(2)
           ...
           c_n*n^n + ... + c_1*n + c_0 = p(0) + p(1) + ... + p(n)

       We then solve for the c_i coefficients to get q *)
    let c0 = V.add_term QQ.one 0 V.zero in
    let rec mk_sys k =
      if k = 0 then begin
        let rhs = eval p QQ.zero in
        (rhs, M.add_row 0 c0 M.zero, V.of_term rhs 0)
      end else begin
        let (prev, mat, b) = mk_sys (k - 1) in
        let qq_k = QQ.of_int k in
        let rhs = QQ.add prev (eval p qq_k) in
        let vars = 1 --- sum_order in
        let lhs =
          (* compute lhs right-to-left: c_0 + k*c_1 + k^2*c_2 ... This avoids
             raising k to increasingly higher powers. *)
          BatEnum.fold
            (fun (lhs, last_coeff) ord ->
               let next_coeff = QQ.mul last_coeff qq_k in
               (V.add_term next_coeff ord lhs, next_coeff))
            (c0, QQ.one)
            vars
          |> fst
        in
        (rhs, M.add_row k lhs mat, V.add_term rhs k b)
      end
    in
    let (_, mat, b) = mk_sys sum_order in
    let coeffs = Linear.solve_exn mat b in
    of_enum (V.enum coeffs)

  let factor p =
    let denominator =
      BatEnum.fold (fun d (coeff, _) ->
          ZZ.lcm d (QQ.denominator coeff))
        ZZ.one
        (enum p)
    in
    let zzx =
      (enum p) /@ (fun (coeff, d) ->
          let (num, den) = QQ.to_zzfrac coeff in
          (d, Ntl.ZZ.of_mpz (ZZ.div (ZZ.mul num denominator) den)))
      |> BatList.of_enum
      |> Ntl.ZZX.of_list
    in
    let (c, factors) = Ntl.ZZX.factor zzx in
    let content = QQ.of_zzfrac (Ntl.ZZ.mpz_of c) denominator in
    let factors =
      List.map (fun (zzx, n) ->
          let qqx =
            BatList.enum (Ntl.ZZX.list_of zzx)
            /@ (fun (degree, coeff) ->
                (QQ.of_zz (Ntl.ZZ.mpz_of coeff), degree))
            |> of_enum
          in
          (qqx, n))
        factors
    in
    (content, factors)

  let content p =
    fold (fun _ coeff content ->
        QQ.gcd coeff content)
      p
      QQ.zero

  let choose k =
    assert (k >= 0);
    let rec go i next p =
      if i = k then
        p
      else
        let next' =
          add_term (QQ.of_int (-1)) 0 next
        in
        go (i + 1) next' (mul next p)
    in
    let rec factorial = function
      | 0 -> 1
      | k -> k*(factorial (k-1))
    in
    scalar_mul (QQ.of_frac 1 (factorial k)) (go 0 identity one)

  let term_of srk term p =
    fold (fun pow coeff product ->
        let term =
          Syntax.mk_mul srk [Syntax.mk_real srk coeff; Syntax.mk_pow srk term pow]
        in
        term::product)
      p
      []
    |> Syntax.mk_add srk
end

module Monomial = struct
  module IntMap = SrkUtil.Int.Map

  type dim = int
  type t = int IntMap.t

  let pp pp_dim formatter monomial =
    if IntMap.is_empty monomial then
      Format.pp_print_string formatter "1"
    else
      SrkUtil.pp_print_enum_nobox
        ~pp_sep:(fun formatter () -> Format.fprintf formatter "*")
        (fun formatter (dim, power) ->
           if power = 1 then
             pp_dim formatter dim
           else
             Format.fprintf formatter "%a^%d"
               pp_dim dim
               power)
        formatter
        (IntMap.enum monomial)

  let one = IntMap.empty

  let mul =
    let f _ a b =
      match a, b with
      | Some a, Some b ->
        if a + b = 0 then None else Some (a + b)
      | Some x, None | None, Some x -> Some x
      | None, None -> assert false
    in
    IntMap.merge f

  let mul_term dim power monomial =
    if power = 0 then monomial else begin
      try
        let power' = power + (IntMap.find dim monomial) in
        if power' = 0 then
          IntMap.remove dim monomial
        else
          IntMap.add dim power' monomial
      with Not_found -> IntMap.add dim power monomial
    end

  let power dim monomial = try IntMap.find dim monomial with Not_found -> 0

  let enum = IntMap.enum

  let of_enum = BatEnum.fold (fun monomial (x,y) -> mul_term x y monomial) one

  let equal = IntMap.equal (=)

  let compare = IntMap.compare Stdlib.compare

  let singleton dim power = mul_term dim power one

  let pivot dim monomial =
    (power dim monomial, IntMap.remove dim monomial)

  exception Undefined
  let div m n =
    try
      Some (IntMap.fold
              (fun dim n_power m ->
                 let m_power = power dim m in
                 if n_power > m_power then
                   raise Undefined
                 else if n_power = m_power then
                   IntMap.remove dim m
                 else
                   IntMap.add dim (m_power - n_power) m)
              n
              m)
    with Undefined -> None

  let lcm =
    let f _ a b =
      match a, b with
      | Some a, Some b -> Some (max a b)
      | Some x, None | None, Some x -> Some x
      | None, None -> assert false
    in
    IntMap.merge f

  let gcd =
    let f _ a b =
      match a, b with
      | Some a, Some b -> Some (min a b)
      | Some _, None | None, Some _ -> None
      | None, None -> assert false
    in
    IntMap.merge f

  let total_degree m =
    IntMap.fold (fun _ degree total -> degree + total) m 0

  let graded partial total m n =
    match partial m n with
    | `Gt -> `Gt
    | `Lt -> `Lt
    | `Pass -> total m n

  let compare_degree m n =
    let deg_diff = (total_degree m) - (total_degree n) in
    if deg_diff = 0 then `Pass
    else if deg_diff > 0 then `Gt
    else `Lt

  let lex m n =
    let mlist = BatList.of_enum (enum m) in
    let nlist = BatList.of_enum (enum n) in
    let rec go m n =
      match m, n with
      | ([], []) -> `Eq
      | ([], _) -> `Lt
      | (_, []) -> `Gt
      | ((x, a)::m', (y, b)::n') ->
        if x = y then
          if a = b then go m' n'
          else if a < b then `Lt
          else `Gt
        else if x < y then `Gt
        else `Lt
    in
    go mlist nlist

  let deglex = graded compare_degree lex
  let degrevlex =
    let revlex m n = match lex m n with
      | `Eq -> `Eq
      | `Lt -> `Gt
      | `Gt -> `Lt
    in
    graded compare_degree revlex

  let split_block p m =
    IntMap.fold (fun dim pow (t,f) ->
        if p dim then
          (IntMap.add dim pow t, f)
        else
          (t, IntMap.add dim pow f))
      m
      (IntMap.empty, IntMap.empty)

  let block blocks compare_block =
    let rec compare blocks m n =
      match blocks with
      | [] -> compare_block m n
      | (block::blocks) ->
        let (m1,m2) = split_block block m in
        let (n1,n2) = split_block block n in
        match compare_block m1 n1 with
        | `Eq -> compare blocks m2 n2
        | cmp -> cmp
    in
    compare blocks

  let term_of srk dim_term m =
    IntMap.fold (fun dim pow product ->
        (Syntax.mk_pow srk (dim_term dim) pow)::product)
      m
      []
    |> Syntax.mk_mul srk
end

module type Multivariate = sig
  type t
  type scalar
  val equal : t -> t -> bool
  val add : t -> t -> t
  val negate : t -> t
  val mul : t -> t -> t
  val zero : t
  val one : t
  val sub : t -> t -> t
  val pp : (Format.formatter -> scalar -> unit) ->
           (Format.formatter -> int -> unit) ->
           Format.formatter ->
           t ->
           unit
  val add_term : scalar -> Monomial.t -> t -> t
  val scalar : scalar -> t
  val of_dim : int -> t
  val scalar_mul : scalar -> t -> t
  val coeff : Monomial.t -> t -> scalar
  val pivot : Monomial.t -> t -> scalar * t
  val enum : t -> (scalar * Monomial.t) BatEnum.t
  val of_enum : (scalar * Monomial.t) BatEnum.t -> t
  val of_list : (scalar * Monomial.t) list -> t
  val exp : t -> int -> t
  val substitute : (int -> t) -> t -> t
  val mul_monomial : Monomial.t -> t -> t
  val div_monomial : t -> Monomial.t -> t option
  val qr_monomial : t -> Monomial.t -> t * t
  val dimensions : t -> SrkUtil.Int.Set.t
  val degree : t -> int
end

module MakeMultivariate(R : Algebra.Ring) = struct
  include Ring.RingMap(Monomial)(R)

  let pp pp_scalar pp_dim formatter p =
    if is_zero p then
      Format.pp_print_string formatter "0"
    else
      SrkUtil.pp_print_enum_nobox
        ~pp_sep:(fun formatter () -> Format.fprintf formatter "@ + ")
        (fun formatter (coeff, m) ->
           if R.equal coeff R.one then
             Format.fprintf formatter "@[%a@]" (Monomial.pp pp_dim) m
           else
             Format.fprintf formatter "@[%a*%a@]" pp_scalar coeff (Monomial.pp pp_dim) m)
        formatter
        (enum p)

  let mul_monomial_scalar coeff monomial p =
    if R.equal coeff R.zero then
      zero
    else
      (enum p)
      /@ (fun (coeff', monomial') ->
          (R.mul coeff coeff', Monomial.mul monomial monomial'))
      |> of_enum

  let mul_monomial = mul_monomial_scalar R.one

  let mul p q =
    BatEnum.fold
      (fun r (coeff, monomial) ->
         add r (mul_monomial_scalar coeff monomial q))
      zero
      (enum p)

  let sub p q = add p (scalar_mul (R.negate R.one) q)

  let scalar k = of_term k Monomial.one

  let one = of_term R.one Monomial.one

  let of_dim dim =
    of_term R.one (Monomial.singleton dim 1)

  let exp = SrkUtil.exp mul one

  let substitute subst p =
    fold (fun monomial coeff p ->
        let q =
          Monomial.IntMap.fold (fun dim pow q ->
              mul q (exp (subst dim) pow))
            monomial
            one
        in
        add p (scalar_mul coeff q))
      p
      zero

  let div_monomial p m =
    fold (fun n coeff p ->
        match p with
        | Some p ->
          begin match Monomial.div n m with
            | Some q -> Some (add_term coeff q p)
            | None -> None
          end
        | None -> None)
      p
      (Some zero)

  let qr_monomial p m =
    fold (fun n coeff (q, r) ->
        match Monomial.div n m with
        | Some qn -> (add_term coeff qn q, r)
        | None -> (q, add_term coeff n r))
      p
      (zero, zero)

  let dimensions p =
    let module S = SrkUtil.Int.Set in
    fold (fun m _ set ->
        Monomial.IntMap.fold (fun dim _ set -> S.add dim set) m set)
      p
      S.empty

  let degree p =
    fold (fun m _ d -> max (Monomial.total_degree m) d) p 0
end

module QQXs = struct
  include MakeMultivariate(QQ)
  module V = Linear.QQVector
  module IntSet = SrkUtil.Int.Set

  let pp pp_dim formatter p =
    if is_zero p then
      Format.pp_print_string formatter "0"
    else
      SrkUtil.pp_print_enum_nobox
        ~pp_sep:(fun formatter () -> Format.fprintf formatter "@ + ")
        (fun formatter (coeff, m) ->
           if QQ.equal coeff QQ.one then
             Format.fprintf formatter "@[%a@]" (Monomial.pp pp_dim) m
           else if QQ.lt coeff QQ.zero then
             Format.fprintf formatter "@[(%a)*%a@]"
               QQ.pp coeff
               (Monomial.pp pp_dim) m
         else
           Format.fprintf formatter "@[%a*%a@]" QQ.pp coeff (Monomial.pp pp_dim) m)
        formatter
        (enum p)

  let of_vec ?(const=Linear.const_dim) vec =
    let (const_coeff, vec) = V.pivot const vec in
    V.enum vec
    /@ (fun (coeff, id) -> scalar_mul coeff (of_dim id))
    |> BatEnum.fold add (scalar const_coeff)

  let split_linear ?(const=Linear.const_dim) p =
    fold (fun monomial coeff (vec, poly) ->
        match BatList.of_enum (Monomial.enum monomial) with
        | [] -> (V.add_term coeff const vec, poly)
        | [(x,1)] -> (V.add_term coeff x vec, poly)
        | _ -> (vec, add_term coeff monomial poly))
      p
      (V.zero, zero)

  let vec_of ?(const=Linear.const_dim) p =
    let (vec, q) = split_linear ~const p in
    if equal q zero then
      Some vec
    else
      None

  let term_of srk dim_term p =
    fold (fun monomial coeff sum ->
        (Syntax.mk_mul srk [Syntax.mk_real srk coeff;
                            Monomial.term_of srk dim_term monomial])::sum)
      p
      []
    |> Syntax.mk_add srk

  let of_term srk term =
    logf "term is %a" (Syntax.ArithTerm.pp srk) term;
    let qq_of poly =
      if (degree poly) > 0 then failwith "Cannot convert non-const term to qq (cannot handle modulo involving variables)"
      else coeff Monomial.one poly
    in
    let nonzero_qq_of poly =
      let qq = qq_of poly in
      if QQ.equal qq QQ.zero then failwith "Cannot divide or modulo zero" else qq
    in
    let alg = function
      | `Real qq -> scalar qq
      | `App (k, []) -> of_dim (Syntax.int_of_symbol k)
      | `Var (_, _) | `App (_, _) -> failwith "Cannot convert functions term to polynomials"
      | `Add sum -> BatList.fold_left add zero sum
      | `Mul prod -> BatList.fold_left mul one prod
      | `Binop (`Div, x, y) -> scalar_mul (QQ.inverse (nonzero_qq_of y)) x
      | `Binop (`Mod, x, y) -> scalar (QQ.modulo (qq_of x) (nonzero_qq_of y))
      | `Unop (`Floor, x) -> scalar (QQ.of_zz (QQ.floor (qq_of x)))
      | `Unop (`Neg, x) -> negate x
      | `Select _ -> assert false
      | `Ite (_, _, _) -> failwith "Cannot convert ite term to polynomials"
    in
    Syntax.ArithTerm.eval srk alg term

  let compare = compare QQ.compare

  let content p =
    fold (fun _ coeff content ->
        QQ.gcd coeff content)
      p
      QQ.zero

  let factor_gcd p =
    if is_zero p then
      (QQ.one, Monomial.one, p)
    else
      let ((m, c), p') = pop p in
      let (c, m) =
        fold (fun monomial coeff (c, m) ->
            (QQ.gcd coeff c, Monomial.gcd m monomial))
          p'
          (c, m)
      in
      let q =
        fold (fun n coeff q ->
            match Monomial.div n m with
            | Some r -> add_term (QQ.div coeff c) r q
            | None -> assert false)
          p
          zero
      in
      (c, m, q)

  let split_leading ord p =
    let leading_monomial =
      fold (fun n _ m ->
          if ord n m = `Gt then n
          else m)
        p
        Monomial.one
    in
    let (coeff, rest) = pivot leading_monomial p in
    (coeff, leading_monomial, rest)
end

module Rewrite = struct
  (* An ordered polynomial (coefficient, monomial) pairs such that the
     monomials *descend* in some admissible order. *)
  type op = (QQ.t * Monomial.t) list [@@deriving ord]

  module P = BatSet.Make(QQXs)

  type rule = Monomial.t * op * P.t [@@deriving ord]

  (* Priority queue of pairs of polynomials, ordered by total degree of the
     LCM of their leading monomials *)
  module PairQueue = struct
    type pair = int * rule * rule [@@deriving ord]

    module H = BatHeap.Make(struct
        type t = pair [@@deriving ord]
      end)
    let insert queue (x, y) =
      let (m, _, _) = x in
      let (m', _, _) = y in
      let deg = Monomial.total_degree (Monomial.lcm m m') in
      if compare_rule x y < 0 then
        H.insert queue (deg, x, y)
      else
        H.insert queue (deg, y, x)
    let pop queue =
      if queue = H.empty then
        None
      else
        let (_, x, y) = H.find_min queue in
        Some ((x, y), H.del_min queue)
    let empty = H.empty

    let mem queue (x, y) =
      let (m, _, _) = x in
      let (m', _, _) = y in
      let deg = Monomial.total_degree (Monomial.lcm m m') in
      let elt =
        if compare_rule x y < 0 then
          (deg, x, y)
        else
          (deg, y, x)
      in
      BatEnum.exists ((=) 0 % compare_pair elt) (H.enum queue)
  end

  module IntSet = SrkUtil.Int.Set

  (* Rule set *)
  module RS = struct
    type t = rule FeatureTree.t
    let enum = FeatureTree.enum
    let features ft m = FeatureTree.features ft (m, [], P.empty)
    let find_leq_map = FeatureTree.find_leq_map
    let insert = FeatureTree.insert
    let remove = FeatureTree.remove (fun x y -> compare_rule x y = 0)
    let of_list rules =
      let () = Random.init 63864283 in
      let nb_dimensions =
        let max_dim m =
          Monomial.IntMap.fold (fun d _ m -> max d m) m 0
        in
        List.fold_left (fun nb_dimensions (n,op,_) ->
            List.fold_left
              (fun x (_, y) -> max x (max_dim y))
              (max nb_dimensions (max_dim n))
              op)
          0
          rules
      in
      let rec log2 n =
        if n == 1 then
          0
        else
          log2 (n / 2) + 1
      in
      let nb_features = (log2 (8 + nb_dimensions)) in
      let feature_sets =
        Array.init nb_features (fun _ ->
            BatEnum.fold (fun set d ->
                if Random.bool () then
                  IntSet.add d set
                else
                  set)
              IntSet.empty
              (0 -- nb_dimensions))
      in
      let features (m,_,_) =
        let fv = Array.make nb_features 0 in
        m |> Monomial.IntMap.iter (fun d p ->
            for i = 0 to (nb_features - 1) do
              if IntSet.mem d feature_sets.(i) then
                fv.(i) <- fv.(i) + p
            done);
        fv
      in
      FeatureTree.of_list features rules
  end

  type t =
    { rules : RS.t;
      order : Monomial.t -> Monomial.t -> [ `Eq | `Lt | `Gt ] }

  let get_monomial_ordering rs = rs.order

  let pp_op pp_dim formatter op =
    match op with
    | [] -> Format.pp_print_string formatter "0"
    | _ ->
    SrkUtil.pp_print_enum_nobox
      ~pp_sep:(fun formatter () -> Format.fprintf formatter "@ + ")
      (fun formatter (coeff, monomial) ->
         if QQ.equal coeff QQ.one then
           Format.fprintf formatter "(%a)"
             (Monomial.pp pp_dim) monomial
         else
           Format.fprintf formatter "%a*(%a)"
             QQ.pp coeff
             (Monomial.pp pp_dim) monomial)
      formatter
      (BatList.enum op)

  let pp pp_dim formatter rewrite =
    SrkUtil.pp_print_enum_nobox
      ~pp_sep:(fun formatter () -> Format.fprintf formatter "@;")
      (fun formatter (lhs, rhs, _) ->
         Format.fprintf formatter "%a --> @[<hov 2>%a@]"
           (Monomial.pp pp_dim) lhs
           (pp_op pp_dim) rhs)
      formatter
      (RS.enum rewrite.rules)

  let rec op_add order p q =
    match p, q with
    | ([], q) -> q
    | (p, []) -> p
    | ((a, m)::p', (b, n)::q') ->
      match order m n with
      | `Eq ->
        let c = QQ.add a b in
        let rest = op_add order p' q' in
        if QQ.equal c QQ.zero then rest
        else (c, m)::rest
      | `Gt -> (a,m)::(op_add order p' q)
      | `Lt -> (b,n)::(op_add order p q')

  let op_monomial_scalar_mul coeff monomial =
    List.map
      (fun (coeff', monomial') ->
        (QQ.mul coeff coeff', Monomial.mul monomial monomial'))

  let op_of_qqxs order p =
    QQXs.enum p
    |> BatList.of_enum
    |> BatList.sort (fun (_, m) (_, n) -> match order m n with
        | `Eq -> 0
        | `Lt -> 1
        | `Gt -> -1)

  let qqxs_of_op p =
    List.fold_left (fun q (c, m) -> QQXs.add_term c m q) QQXs.zero p

  let rec reduce_op rewrite polynomial =
    match polynomial with
    | [] -> ([], P.empty)
    | (c, m)::polynomial' ->
      try
        let (reduced, provenance) =
          RS.find_leq_map (RS.features rewrite.rules m) (fun (n, p, provenance) ->
              match Monomial.div m n with
              | Some remainder ->
                Some (op_monomial_scalar_mul c remainder p, provenance)
              | None -> None)
            rewrite.rules
        in
        let (reduced', provenance') =
          reduce_op rewrite (op_add rewrite.order reduced polynomial')
        in
        (reduced', P.union provenance provenance')
      with Not_found ->
        let (reduced, provenance) = reduce_op rewrite polynomial' in
        (op_add rewrite.order [(c, m)] reduced, provenance)

  let preduce rewrite polynomial =
    let (reduced, provenance) =
      reduce_op rewrite (op_of_qqxs rewrite.order polynomial)
    in
    (qqxs_of_op reduced, P.elements provenance)

  let reduce rewrite polynomial =
    let (reduced, _) =
      reduce_op rewrite (op_of_qqxs rewrite.order polynomial)
    in
    qqxs_of_op reduced

  let mk_rewrite order polynomials =
    let rule_list =
      polynomials |> BatList.filter_map (fun polynomial ->
          let op = op_of_qqxs order polynomial in
          match op with
          | [] -> None
          | (c, m)::rest ->
            assert (not (QQ.equal c QQ.zero));
            let rhs =
              op_monomial_scalar_mul (QQ.negate (QQ.inverse c)) Monomial.one rest
            in
            Some (m, rhs, P.singleton polynomial))
    in
    { rules = RS.of_list rule_list;
      order }

  (* Buchberger's second criterion *)
  let _criterion2 r r' pairs rules =
    let lcm =
      let (m, _, _) = r in
      let (m', _, _) = r' in
      Monomial.lcm m m'
    in
    List.exists (fun rule ->
        let (m, _, _) = rule in
        (Monomial.div m lcm) != None
        && not (PairQueue.mem pairs (r, rule))
        && not (PairQueue.mem pairs (r', rule)))
      rules

  let pp_dim formatter i =
    let rec to_string i =
      if i < 26 then
        Char.escaped (Char.chr (97 + i))
      else
        (to_string (i/26)) ^ (Char.escaped (Char.chr (97 + (i mod 26))))
    in
    Format.pp_print_string formatter (to_string i)

  let buchberger order rules pairs =
    (* Suppose m1 = rhs1 and m2 = rhs1.  Let m be the least common multiple of
       m1 and m2, and let m1*r1 = m = m2*r2.  Then we have m = rhs1*r1 and m =
       rhs2*r1.  It follows that rhs1*r1 - rhs2*r2 = 0.  spoly computes this
       polynomial. *)
    let spoly (m1, rhs1, provenance1) (m2, rhs2, provenance2) =
      let m = Monomial.lcm m1 m2 in
      let r1 = BatOption.get (Monomial.div m m1) in
      let r2 = BatOption.get (Monomial.div m m2) in
      (op_add
         order
         (op_monomial_scalar_mul QQ.one r1 rhs1)
         (op_monomial_scalar_mul (QQ.of_int (-1)) r2 rhs2),
       P.union provenance1 provenance2)
    in
    let lhs (x, _, _) = x in
    let rhs (_, x, _) = x in
    let rec go rules pairs =
      match PairQueue.pop pairs with
      | None -> rules
      | Some ((r1, r2), pairs) ->
        logf ~level:`trace  "Pair:";
        logf ~level:`trace  "  @[%a@] --> @[<hov 2>%a@]"
          (Monomial.pp pp_dim) (lhs r1)
          (pp_op pp_dim) (rhs r1);
        logf ~level:`trace  "  @[%a@] --> @[<hov 2>%a@]"
          (Monomial.pp pp_dim) (lhs r2)
          (pp_op pp_dim) (rhs r2);
        let (sp, provenance) = spoly r1 r2 in
        match reduce_op { order = order; rules = rules } sp with
        | ([], _) -> go rules pairs
        | ([(c,m)], provenance') when Monomial.equal m Monomial.one ->
          (* Inconsistent -- return (1 = 0) *)
          assert (not (QQ.equal c QQ.zero));
          (RS.of_list [(Monomial.one, [], P.union provenance provenance')])
        | ((c,m)::rest, provenance') ->
          assert (not (QQ.equal c QQ.zero));
          let rhs =
            op_monomial_scalar_mul (QQ.negate (QQ.inverse c)) Monomial.one rest
          in
          logf ~level:`trace "Result:";
          logf ~level:`trace "  @[%a@] --> @[<hov 2>%a@]"
            (Monomial.pp pp_dim) m
            (pp_op pp_dim) rhs;
          let new_rule = (m,rhs,P.union provenance provenance') in
          let pairs =
            BatEnum.fold (fun pairs rule ->
                match rule with
                | (m', _, _) when Monomial.equal (Monomial.gcd m m') Monomial.one ->
                  pairs
                | _ ->
                  PairQueue.insert pairs (new_rule, rule))
              pairs
              (RS.enum rules)
          in
          go
            (RS.insert new_rule rules)
            pairs
    in
    go rules pairs

  let buchberger order rules pairs =
    Log.time "buchberger" (buchberger order rules) pairs

  (* Ensure that every basis polynomial is irreducible w.r.t. every other
     basis polynomial *)
  let reduce_rewrite rewrite =
    let rules =
      BatEnum.fold (fun rules rule ->
        let (m, rhs, provenance) = rule in
        let rules = RS.remove rule rules in
        match reduce_op {rewrite with rules=rules} ((QQ.negate QQ.one, m)::rhs) with
        | ([], _) -> rules
        | ([(c,m)], provenance') when Monomial.equal m Monomial.one ->
          (* Inconsistent -- return (1 = 0) *)
          assert (not (QQ.equal c QQ.zero));
          RS.of_list [(Monomial.one, [], P.union provenance provenance')]
        | ((c,m)::rest, provenance') ->
          assert (not (QQ.equal c QQ.zero));
          let rhs =
            op_monomial_scalar_mul (QQ.negate (QQ.inverse c)) Monomial.one rest
          in
          RS.insert (m, rhs, P.union provenance provenance') rules)
        rewrite.rules
        (RS.enum rewrite.rules)
    in
    { order = rewrite.order; rules = rules }

  let add_saturate_op rewrite op provenance =
    match reduce_op rewrite op with
    | ([], _) -> rewrite
    | ([(c,m)], provenance') when Monomial.equal m Monomial.one ->
      (* Inconsistent -- return (1 = 0) *)
      assert (not (QQ.equal c QQ.zero));
      { order = rewrite.order;
        rules = RS.of_list [(Monomial.one, [], P.union provenance provenance')] }
    | ((c,m)::rest, provenance') ->
      assert (not (QQ.equal c QQ.zero));
      let rhs =
        op_monomial_scalar_mul (QQ.negate (QQ.inverse c)) Monomial.one rest
      in
      let new_rule = (m, rhs, P.union provenance provenance') in
      let pairs =
        BatEnum.fold (fun pairs rule ->
            match rule with
            | (m', _, _) when Monomial.equal (Monomial.gcd m m') Monomial.one ->
              pairs
            | _ ->
              PairQueue.insert pairs (new_rule, rule))
          PairQueue.empty
          (RS.enum rewrite.rules)
      in
      { order = rewrite.order;
        rules = buchberger rewrite.order
            (RS.insert new_rule rewrite.rules)
            pairs }
      |> reduce_rewrite

  let add_saturate rewrite p =
    add_saturate_op rewrite (op_of_qqxs rewrite.order p) (P.singleton p)

  let grobner_basis rewrite =
    logf ~level:`trace "Compute a Grobner basis for:@\n@[<v 0>%a@]"
      (pp pp_dim) rewrite;

    let rewrite = reduce_rewrite rewrite in

    logf ~level:`trace "After reduction:@\n@[<v 0>%a@]"
      (pp pp_dim) rewrite;

    let pairs =
      BatEnum.fold (fun pairs (rule, rule') ->
          let (m, _, _) = rule in
          let (m', _, _) = rule' in
          if Monomial.equal (Monomial.gcd m m') Monomial.one then
            pairs
          else
            PairQueue.insert pairs (rule, rule'))
        PairQueue.empty
        (SrkUtil.distinct_pairs (RS.enum rewrite.rules))
    in

    let grobner =
      { order = rewrite.order;
        rules = buchberger rewrite.order rewrite.rules pairs }
      |> reduce_rewrite
    in
    logf ~level:`trace "Grobner basis:@\n@[<v 0>%a@]"
      (pp pp_dim) grobner;
    grobner

  let op_generators rewrite =
    RS.enum rewrite.rules
    /@ (fun (lt, op, _) -> ((QQ.of_int (-1), lt)::op))
    |> BatList.of_enum

  let generators rewrite =
    RS.enum rewrite.rules
    /@ (fun (lt, op, _) -> qqxs_of_op ((QQ.of_int (-1), lt)::op))
    |> BatList.of_enum

  let reorder_groebner order p = 
    (* Trivial conversion now.  TODO: implement Groebner walk *)
    grobner_basis (mk_rewrite order (generators p))

  let subset j k =
    BatEnum.for_all
      (fun (m, rhs, _) ->
         fst (reduce_op k ((QQ.of_int (-1), m)::rhs)) = [])
      (RS.enum j.rules)

  let equal j k = subset j k && subset k j
end


module Ideal = struct
  type t = Rewrite.t
  open Rewrite

  (* Common monomial ordering *)
  let order = Monomial.degrevlex
  
  let add_saturate ideal p = Rewrite.add_saturate ideal p

  let reduce ideal p = 
    Rewrite.reduce ideal p

  (* Projection of the ideal generated by a set of polynomials *)
  let project_impl p generators =
    let elim_order = Monomial.block [not % p] order in
    let rewrite =
      mk_rewrite elim_order generators
      |> grobner_basis
    in
    let rules =
      RS.enum rewrite.rules
      |> BatEnum.filter (fun (m, _, _) ->
          BatEnum.for_all (fun (d, _) -> p d) (Monomial.enum m))
      |> BatList.of_enum
      |> RS.of_list
    in
    { order; rules }

  let project p j = project_impl p (generators j)

  let intersect j k =
    let j = generators j in
    let k = generators k in
    let t =
      1 + (List.fold_left
             (fun m p ->
                try max m (SrkUtil.Int.Set.max_elt (QQXs.dimensions p))
                with Not_found -> m)
             0
             (j @ k))
    in
    (* { tp : p in j } *)
    let j' = List.map (QQXs.mul (QQXs.of_dim t)) j in
    (* { (1-t)p : p in k } *)
    let k' =
      List.map (QQXs.mul (QQXs.sub (QQXs.scalar QQ.one) (QQXs.of_dim t))) k
    in
    project_impl (not % (=) t) (j' @ k')

  let mem p j =
    (fst (reduce_op j (op_of_qqxs order p))) = []

  let subset = subset

  let equal = equal

  let make generators =
    grobner_basis (mk_rewrite order generators)

  let generators = generators

  let product j k =
    let j_generators = generators j in
    List.fold_left (fun gen p ->
        List.fold_left (fun gen q ->
            (QQXs.mul p q)::gen)
          gen
          j_generators)
      []
      (generators k)
    |> make

  let sum j k =
    List.fold_left (fun rewrite q ->
        add_saturate_op rewrite q P.empty)
      j
      (op_generators k)

  let pp = pp
end
