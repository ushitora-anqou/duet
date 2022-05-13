(** Convex cones. *)

open Linear

(** A cone is a non-empty set of vectors that is closed under addition
   and scalar multiplication by non-negative rationals. *)
type t

(** Given a matrix M and a vector v, find a non-negative x such that
   Mx = v. *)
val simplex : QQVector.t array -> QQVector.t -> QQVector.t option

(** [mem v C] determines whether the vector [v] belongs to the cone [C]. *)
val mem : QQVector.t -> t -> bool

(** [make L R n] creates the smallest n-dimensional cone which
   contains L, -L, and R. *)
val make : lines:QQVector.t list -> rays:QQVector.t list -> int -> t

(** The lines in the *representation* of the cone.  If the cone is
   [minimize]d, the lines are generators for the lineality space of
   the cone. *)
val lines : t -> QQVector.t list

(** The rays in the *representation* of the cone.  If the cone is
   [minimize]d, its rays generate a salient cone (the cone contains no
   lines) and any proper subset generate a proper subcone. *)
val rays : t -> QQVector.t list

(** The lineality space of a cone is the smallest linear space
   contained in the cone. *)
val lineality : t -> QQVectorSpace.t

(** Minimize the representation of the cone.  After minimization,
   [lines] generates the lineality space of the cone, and [rays] is
   salient (contains no lines) and irredundant (any proper subset
   generates a proper subcone). *)
val minimize : t -> unit

(** Normalize the representation of the cone.  After minimization,
    [lines] generates the lineality space of the cone, and [rays] is
    salient (contains no lines) *)
val normalize : t -> unit

(** [generators C] is a list of vectors [g1...,gn] such that [C =
   cone({g1,...,gn})]. *)
val generators : t -> QQVector.t list

(** [image M C] computes the cone { Mv : v in C } *)
val image : QQMatrix.t -> t -> t

(** [join C1 c2] is the smallest cone that contains C1 and C2. *)
val join : t -> t -> t

(** [join C1 c2] is the smallest cone that contains C1 and C2. *)
val meet : t -> t -> t

(** [dual C1] computes the dual cone of [C1]: [ v in dual C <==> vc >= 0 for
   all c in C ] *)
val dual : t -> t

(** [leq C1 C2] checks if the cone [C1] is contained inside [C2]. *)
val leq : t -> t -> bool

(** [equal C1 C2] checks if two cones are equal (contain the same elements) *)
val equal : t -> t -> bool

(** Dimension of a cone. *)
val dim : t -> int

(** Pretty print *)
val pp : Format.formatter -> t -> unit
