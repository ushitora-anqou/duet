(** Polynomial cone abstract domain. A polynomial cone corresponds to a set of polynomials.
    It is used to maintain a maximal set of non-negative polynomials w.r.t. the weak theory. *)
open Polynomial
open Syntax

type t

val pp : (Format.formatter -> int -> unit) -> Format.formatter -> t -> unit

(** Compute the intersection of two polynomial cones. Intersection of polynomial cones A, B corresponds
    to the join of their corresponding polynomial equations and inequalities. *)
val intersection : t -> t -> t

(** Compute the projection of a polynomial cone, given what dimensions to keep. *)
val project : t -> (int -> bool) -> t

(** Get the ideal part of a polynomial cone. *)
val get_ideal : t -> Rewrite.t

(** Get the cone part of a polynomial cone. *)
val get_cone_generators : t -> (QQXs.t BatList.t)

(** Change the monomial ordering of a polynomial cone. *)
val change_monomial_ordering: t ->
  (Monomial.t -> Monomial.t -> [ `Eq | `Lt | `Gt  ]) -> t

(** A polynomial cone that corresponds to the empty set of polynomials. *)
val trivial : t

(** Compute the maximal polynomial cone that contains a given ideal and a given set of nonnegative polynomials. *)
val make_enclosing_cone : Polynomial.Rewrite.t -> QQXs.t BatList.t -> t

(** Adding a list of zero polynomials and a list of nonnegative polynomials to the set represented by an existing cone. *)
val add_polys_to_cone : t -> QQXs.t BatList.t -> QQXs.t BatList.t -> t

(** Test if a polynomial is contained in the cone. *)
val mem : QQXs.t -> t -> bool

(** Test if a polynomial cone is proper. This is equivalent to querying if -1 belongs to this cone. *)
val is_proper: t -> bool

(** Test if two polynomial cones are equal. The internal representation of polynomials cones is unique
    so that two polynomial cones are equal iff they have the same ideal and the same cone generators
    under the same monomial ordering. *)
val equal: t -> t -> bool

(** Compute a (finite) formula representation of a polynomial cone. *)
val to_formula : 'a context -> (int -> 'a arith_term) -> t -> 'a formula
