(* 
 * CoqUp: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *)

From compcert Require Import Maps.
From compcert Require Errors.
From compcert Require Import AST RTL.
From coqup Require Import Verilog HTL Coquplib AssocMap Value Statemonad.

Hint Resolve AssocMap.gempty : htlh.
Hint Resolve AssocMap.gso : htlh.
Hint Resolve AssocMap.gss : htlh.
Hint Resolve Ple_refl : htlh.
Hint Resolve Ple_succ : htlh.

Record state: Type := mkstate {
  st_st : reg;
  st_freshreg: reg;
  st_freshstate: node;
  st_datapath: datapath;
  st_controllogic: controllogic;
}.

Definition init_state (st : reg) : state :=
  mkstate st
          1%positive
          1%positive
          (AssocMap.empty stmnt)
          (AssocMap.empty stmnt).

Module HTLState <: State.

  Definition st := state.

  Inductive st_incr: state -> state -> Prop :=
    state_incr_intro:
      forall (s1 s2: state),
        st_st s1 = st_st s2 ->
        Ple s1.(st_freshreg) s2.(st_freshreg) ->
        Ple s1.(st_freshstate) s2.(st_freshstate) ->
        (forall n,
            s1.(st_datapath)!n = None \/ s2.(st_datapath)!n = s1.(st_datapath)!n) ->
        (forall n,
            s1.(st_controllogic)!n = None
            \/ s2.(st_controllogic)!n = s1.(st_controllogic)!n) ->
        st_incr s1 s2.
  Hint Constructors st_incr : htlh.

  Definition st_prop := st_incr.
  Hint Unfold st_prop : htlh.

  Lemma st_refl : forall s, st_prop s s. Proof. auto with htlh. Qed.

  Lemma st_trans :
    forall s1 s2 s3, st_prop s1 s2 -> st_prop s2 s3 -> st_prop s1 s3.
  Proof.
    intros. inv H. inv H0. apply state_incr_intro; eauto using Ple_trans.
    - rewrite H1. rewrite H. reflexivity.
    - intros. destruct H4 with n.
      + left; assumption.
      + destruct H8 with n;
          [ rewrite <- H0; left; assumption
          | right; rewrite <- H0; apply H10
          ].
    - intros. destruct H5 with n.
      + left; assumption.
      + destruct H9 with n.
        * rewrite <- H0. left. assumption.
        * right. rewrite <- H0. apply H10.
  Qed.

End HTLState.
Export HTLState.

Module HTLMonad := Statemonad(HTLState).
Export HTLMonad.

Module HTLMonadExtra := Monad.MonadExtra(HTLMonad).
Import HTLMonadExtra.
Export MonadNotation.

Definition state_goto (st : reg) (n : node) : stmnt :=
  Vnonblock (Vvar st) (Vlit (posToValue 32 n)).

Definition state_cond (st : reg) (c : expr) (n1 n2 : node) : stmnt :=
  Vnonblock (Vvar st) (Vternary c (posToExpr 32 n1) (posToExpr 32 n2)).

Definition check_empty_node_datapath:
  forall (s: state) (n: node), { s.(st_datapath)!n = None } + { True }.
Proof.
  intros. case (s.(st_datapath)!n); intros. right; auto. left; auto.
Defined.

Definition check_empty_node_controllogic:
  forall (s: state) (n: node), { s.(st_controllogic)!n = None } + { True }.
Proof.
  intros. case (s.(st_controllogic)!n); intros. right; auto. left; auto.
Defined.

Lemma add_instr_state_incr :
  forall s n n' st,
    (st_datapath s)!n = None ->
    (st_controllogic s)!n = None ->
    st_incr s
    (mkstate
       s.(st_st)
       s.(st_freshreg)
       (st_freshstate s)
       (AssocMap.add n st s.(st_datapath))
       (AssocMap.add n (state_goto s.(st_st) n') s.(st_controllogic))).
Proof.
  constructor; intros;
    try (simpl; destruct (peq n n0); subst);
    auto with htlh.
Qed.

Definition add_instr (n : node) (n' : node) (st : stmnt) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left STM, left TRANS =>
      OK tt (mkstate
               s.(st_st)
               s.(st_freshreg)
               (st_freshstate s)
               (AssocMap.add n st s.(st_datapath))
               (AssocMap.add n (state_goto s.(st_st) n') s.(st_controllogic)))
         (add_instr_state_incr s n n' st STM TRANS)
    | _, _ => Error (Errors.msg "HTL.add_instr")
    end.

Lemma add_instr_skip_state_incr :
  forall s n st,
    (st_datapath s)!n = None ->
    (st_controllogic s)!n = None ->
    st_incr s
    (mkstate
       s.(st_st)
       s.(st_freshreg)
       (st_freshstate s)
       (AssocMap.add n st s.(st_datapath))
       (AssocMap.add n Vskip s.(st_controllogic))).
Proof.
  constructor; intros;
    try (simpl; destruct (peq n n0); subst);
    auto with htlh.
Qed.

Definition add_instr_skip (n : node) (st : stmnt) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left STM, left TRANS =>
      OK tt (mkstate
               s.(st_st)
               s.(st_freshreg)
               (st_freshstate s)
               (AssocMap.add n st s.(st_datapath))
               (AssocMap.add n Vskip s.(st_controllogic)))
         (add_instr_skip_state_incr s n st STM TRANS)
    | _, _ => Error (Errors.msg "HTL.add_instr")
    end.

Definition nonblock (dst : reg) (e : expr) := Vnonblock (Vvar dst) e.
Definition block (dst : reg) (e : expr) := Vblock (Vvar dst) e.

Definition bop (op : binop) (r1 r2 : reg) : expr :=
  Vbinop op (Vvar r1) (Vvar r2).

Definition boplit (op : binop) (r : reg) (l : Integers.int) : expr :=
  Vbinop op (Vvar r) (Vlit (intToValue l)).

Definition boplitz (op: binop) (r: reg) (l: Z) : expr :=
  Vbinop op (Vvar r) (Vlit (ZToValue 32%nat l)).

Definition translate_comparison (c : Integers.comparison) (args : list reg) : mon expr :=
  match c, args with
  | Integers.Ceq, r1::r2::nil => ret (bop Veq r1 r2)
  | Integers.Cne, r1::r2::nil => ret (bop Vne r1 r2)
  | Integers.Clt, r1::r2::nil => ret (bop Vlt r1 r2)
  | Integers.Cgt, r1::r2::nil => ret (bop Vgt r1 r2)
  | Integers.Cle, r1::r2::nil => ret (bop Vle r1 r2)
  | Integers.Cge, r1::r2::nil => ret (bop Vge r1 r2)
  | _, _ => error (Errors.msg "Veriloggen: comparison instruction not implemented: other")
  end.

Definition translate_comparison_imm (c : Integers.comparison) (args : list reg) (i: Integers.int)
  : mon expr :=
  match c, args with
  | Integers.Ceq, r1::nil => ret (boplit Veq r1 i)
  | Integers.Cne, r1::nil => ret (boplit Vne r1 i)
  | Integers.Clt, r1::nil => ret (boplit Vlt r1 i)
  | Integers.Cgt, r1::nil => ret (boplit Vgt r1 i)
  | Integers.Cle, r1::nil => ret (boplit Vle r1 i)
  | Integers.Cge, r1::nil => ret (boplit Vge r1 i)
  | _, _ => error (Errors.msg "Veriloggen: comparison_imm instruction not implemented: other")
  end.

Definition translate_condition (c : Op.condition) (args : list reg) : mon expr :=
  match c, args with
  | Op.Ccomp c, _ => translate_comparison c args
  | Op.Ccompu c, _ => translate_comparison c args
  | Op.Ccompimm c i, _ => translate_comparison_imm c args i
  | Op.Ccompuimm c i, _ => translate_comparison_imm c args i
  | Op.Cmaskzero n, _ => error (Errors.msg "Veriloggen: condition instruction not implemented: Cmaskzero")
  | Op.Cmasknotzero n, _ => error (Errors.msg "Veriloggen: condition instruction not implemented: Cmasknotzero")
  | _, _ => error (Errors.msg "Veriloggen: condition instruction not implemented: other")
  end.

Definition translate_eff_addressing (a: Op.addressing) (args: list reg) : mon expr :=
  match a, args with
  | Op.Aindexed off, r1::nil => ret (boplitz Vadd r1 off)
  | Op.Aindexed2 off, r1::r2::nil => ret (Vbinop Vadd (Vvar r1) (boplitz Vadd r2 off))
  | Op.Ascaled scale offset, r1::nil =>
    ret (Vbinop Vadd (boplitz Vadd r1 scale) (Vlit (ZToValue 32%nat offset)))
  | Op.Aindexed2scaled scale offset, r1::r2::nil =>
    ret (Vbinop Vadd (boplitz Vadd r1 offset) (boplitz Vmul r2 scale))
  | _, _ => error (Errors.msg "Veriloggen: eff_addressing instruction not implemented: other")
  end.

(** Translate an instruction to a statement. *)
Definition translate_instr (op : Op.operation) (args : list reg) : mon expr :=
  match op, args with
  | Op.Omove, r::nil => ret (Vvar r)
  | Op.Ointconst n, _ => ret (Vlit (intToValue n))
  | Op.Oneg, r::nil => ret (Vunop Vneg (Vvar r))
  | Op.Osub, r1::r2::nil => ret (bop Vsub r1 r2)
  | Op.Omul, r1::r2::nil => ret (bop Vmul r1 r2)
  | Op.Omulimm n, r::nil => ret (boplit Vmul r n)
  | Op.Omulhs, _ => error (Errors.msg "Veriloggen: Instruction not implemented: Omulhs")
  | Op.Omulhu, _ => error (Errors.msg "Veriloggen: Instruction not implemented: Omulhu")
  | Op.Odiv, r1::r2::nil => ret (bop Vdiv r1 r2)
  | Op.Odivu, r1::r2::nil => ret (bop Vdivu r1 r2)
  | Op.Omod, r1::r2::nil => ret (bop Vmod r1 r2)
  | Op.Omodu, r1::r2::nil => ret (bop Vmodu r1 r2)
  | Op.Oand, r1::r2::nil => ret (bop Vand r1 r2)
  | Op.Oandimm n, r::nil => ret (boplit Vand r n)
  | Op.Oor, r1::r2::nil => ret (bop Vor r1 r2)
  | Op.Oorimm n, r::nil => ret (boplit Vor r n)
  | Op.Oxor, r1::r2::nil => ret (bop Vxor r1 r2)
  | Op.Oxorimm n, r::nil => ret (boplit Vxor r n)
  | Op.Onot, r::nil => ret (Vunop Vnot (Vvar r))
  | Op.Oshl, r1::r2::nil => ret (bop Vshl r1 r2)
  | Op.Oshlimm n, r::nil => ret (boplit Vshl r n)
  | Op.Oshr, r1::r2::nil => ret (bop Vshr r1 r2)
  | Op.Oshrimm n, r::nil => ret (boplit Vshr r n)
  | Op.Oshrximm n, r::nil => error (Errors.msg "Veriloggen: Instruction not implemented: Oshrximm")
  | Op.Oshru, r1::r2::nil => error (Errors.msg "Veriloggen: Instruction not implemented: Oshru")
  | Op.Oshruimm n, r::nil => error (Errors.msg "Veriloggen: Instruction not implemented: Oshruimm")
  | Op.Ororimm n, r::nil => error (Errors.msg "Veriloggen: Instruction not implemented: Ororimm")
  | Op.Oshldimm n, r::nil => error (Errors.msg "Veriloggen: Instruction not implemented: Oshldimm")
  | Op.Ocmp c, _ => translate_condition c args
  | Op.Olea a, _ => translate_eff_addressing a args
  | _, _ => error (Errors.msg "Veriloggen: Instruction not implemented: other")
  end.

Lemma add_branch_instr_state_incr:
  forall s e n n1 n2,
    (st_datapath s) ! n = None ->
    (st_controllogic s) ! n = None ->
    st_incr s (mkstate
                 s.(st_st)
                (st_freshreg s)
                (st_freshstate s)
                (AssocMap.add n Vskip (st_datapath s))
                (AssocMap.add n (state_cond s.(st_st) e n1 n2) (st_controllogic s))).
Proof.
  intros. apply state_incr_intro; simpl;
            try (intros; destruct (peq n0 n); subst);
            auto with htlh.
Qed.

Definition add_branch_instr (e: expr) (n n1 n2: node) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left NSTM, left NTRANS =>
      OK tt (mkstate
               s.(st_st)
                (st_freshreg s)
                (st_freshstate s)
                (AssocMap.add n Vskip (st_datapath s))
                (AssocMap.add n (state_cond s.(st_st) e n1 n2) (st_controllogic s)))
         (add_branch_instr_state_incr s e n n1 n2 NSTM NTRANS)
    | _, _ => Error (Errors.msg "Veriloggen: add_branch_instr")
    end.

Definition transf_instr (fin rtrn: reg) (ni: node * instruction) : mon unit :=
  match ni with
    (n, i) =>
    match i with
    | Inop n' => add_instr n n' Vskip
    | Iop op args dst n' =>
      do instr <- translate_instr op args;
      add_instr n n' (nonblock dst instr)
    | Iload _ _ _ _ _ => error (Errors.msg "Loads are not implemented.")
    | Istore _ _ _ _ _ => error (Errors.msg "Stores are not implemented.")
    | Icall _ _ _ _ _ => error (Errors.msg "Calls are not implemented.")
    | Itailcall _ _ _ => error (Errors.msg "Tailcalls are not implemented.")
    | Ibuiltin _ _ _ _ => error (Errors.msg "Builtin functions not implemented.")
    | Icond cond args n1 n2 =>
      do e <- translate_condition cond args;
      add_branch_instr e n n1 n2
    | Ijumptable _ _ => error (Errors.msg "Jumptable not implemented")
    | Ireturn r =>
      match r with
      | Some r' =>
        add_instr_skip n (Vseq (block fin (Vlit (ZToValue 1%nat 1%Z))) (block rtrn (Vvar r')))
      | None =>
        add_instr_skip n (Vseq (block fin (Vlit (ZToValue 1%nat 1%Z))) (block rtrn (Vlit (ZToValue 1%nat 0%Z))))
      end
    end
  end.

Lemma create_reg_state_incr:
  forall s,
    st_incr s (mkstate
         s.(st_st)
         (Pos.succ (st_freshreg s))
         (st_freshstate s)
         (st_datapath s)
         (st_controllogic s)).
Proof. constructor; simpl; auto with htlh. Qed.

Definition create_reg: mon reg :=
  fun s => let r := s.(st_freshreg) in
           OK r (mkstate
                   s.(st_st)
                   (Pos.succ r)
                   (st_freshstate s)
                   (st_datapath s)
                   (st_controllogic s))
              (create_reg_state_incr s).

Definition transf_module (f: function) : mon module :=
  do fin <- create_reg;
  do rtrn <- create_reg;
  do _ <- collectlist (transf_instr fin rtrn) (Maps.PTree.elements f.(RTL.fn_code));
  do start <- create_reg;
  do rst <- create_reg;
  do clk <- create_reg;
  do current_state <- get;
  ret (mkmodule
         f.(RTL.fn_params)
         current_state.(st_datapath)
         current_state.(st_controllogic)
         f.(fn_entrypoint)
         current_state.(st_st)
         fin
         rtrn).

Definition max_state (f: function) : state :=
  let st := Pos.succ (max_reg_function f) in
  mkstate st
          (Pos.succ st)
          (Pos.succ (max_pc_function f))
          (st_datapath (init_state st))
          (st_controllogic (init_state st)).

Definition transl_module (f : function) : Errors.res module :=
  run_mon (max_state f) (transf_module f).

Fixpoint main_function (main : ident) (flist : list (ident * AST.globdef fundef unit))
{struct flist} : option function :=
  match flist with
  | (i, AST.Gfun (AST.Internal f)) :: xs =>
    if Pos.eqb i main
    then Some f
    else main_function main xs
  | _ :: xs => main_function main xs
  | nil => None
  end.

Definition transf_program (d : program) : Errors.res module :=
  match main_function d.(AST.prog_main) d.(AST.prog_defs) with
  | Some f => transl_module f
  | _ => Errors.Error (Errors.msg "HTL: could not find main function")
  end.
