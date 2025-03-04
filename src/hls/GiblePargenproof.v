(*
 * Vericert: Verified high-level synthesis.
 * Copyright (C) 2020-2022 Yann Herklotz <yann@yannherklotz.com>
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

Require Import compcert.backend.Registers.
Require Import compcert.common.AST.
Require Import compcert.common.Errors.
Require Import compcert.common.Linking.
Require Import compcert.common.Globalenvs.
Require Import compcert.common.Memory.
Require Import compcert.common.Values.
Require Import compcert.lib.Maps.

Require Import vericert.common.Vericertlib.
Require Import vericert.hls.GibleSeq.
Require Import vericert.hls.GiblePar.
Require Import vericert.hls.Gible.
Require Import vericert.hls.GiblePargen.
Require Import vericert.hls.Predicate.
Require Import vericert.hls.Abstr.
Require Import vericert.common.Monad.

Module OptionExtra := MonadExtra(Option).
Import OptionExtra.

#[local] Open Scope positive.
#[local] Open Scope forest.
#[local] Open Scope pred_op.

(*|
==============
RTLPargenproof
==============

RTLBlock to abstract translation
================================

Correctness of translation from RTLBlock to the abstract interpretation language.
|*)

Definition is_regs i := match i with mk_instr_state rs _ _ => rs end.
Definition is_mem i := match i with mk_instr_state _ _ m => m end.
Definition is_ps i := match i with mk_instr_state _ p _ => p end.

Inductive state_lessdef : instr_state -> instr_state -> Prop :=
  state_lessdef_intro :
    forall rs1 rs2 ps1 ps2 m1,
      (forall x, rs1 !! x = rs2 !! x) ->
      (forall x, ps1 !! x = ps2 !! x) ->
      state_lessdef (mk_instr_state rs1 ps1 m1) (mk_instr_state rs2 ps2 m1).

Lemma state_lessdef_refl x : state_lessdef x x.
Proof. destruct x; constructor; auto. Qed.

Lemma state_lessdef_symm x y : state_lessdef x y -> state_lessdef y x.
Proof. destruct x; destruct y; inversion 1; subst; simplify; constructor; auto. Qed.

Lemma state_lessdef_trans :
  forall a b c,
    state_lessdef a b ->
    state_lessdef b c ->
    state_lessdef a c.
Proof.
  inversion 1; inversion 1; subst; simplify.
  constructor; eauto; intros. rewrite H0. auto.
Qed.

#[global] Instance Equivalence_state_lessdef : Equivalence state_lessdef :=
  { Equivalence_Reflexive := state_lessdef_refl;
    Equivalence_Symmetric := state_lessdef_symm;
    Equivalence_Transitive := state_lessdef_trans;
  }.

Definition check_dest i r' :=
  match i with
  | RBop p op rl r => (r =? r')%positive
  | RBload p chunk addr rl r => (r =? r')%positive
  | _ => false
  end.

Lemma check_dest_dec i r : {check_dest i r = true} + {check_dest i r = false}.
Proof. destruct (check_dest i r); tauto. Qed.

Fixpoint check_dest_l l r :=
  match l with
  | nil => false
  | a :: b => check_dest a r || check_dest_l b r
  end.

Lemma check_dest_l_forall :
  forall l r,
  check_dest_l l r = false ->
  Forall (fun x => check_dest x r = false) l.
Proof. induction l; crush. Qed.

Lemma check_dest_l_dec i r : {check_dest_l i r = true} + {check_dest_l i r = false}.
Proof. destruct (check_dest_l i r); tauto. Qed.

(* Lemma check_dest_update : *)
(*   forall f f' i r, *)
(*   check_dest i r = false -> *)
(*   update (Some f) i = Some f' -> *)
(*   (snd f') # (Reg r) = (snd f) # (Reg r). *)
(* Proof. *)
(*   destruct i; crush; try apply Pos.eqb_neq in H; unfold update; destruct_match; crush. *)
(*   inv Heqp. *)
(*   Admitted. *)

(* Lemma check_dest_l_forall2 : *)
(*   forall l r, *)
(*   Forall (fun x => check_dest x r = false) l -> *)
(*   check_dest_l l r = false. *)
(* Proof. *)
(*   induction l; crush. *)
(*   inv H. apply orb_false_intro; crush. *)
(* Qed. *)

(* Lemma check_dest_l_ex2 : *)
(*   forall l r, *)
(*   (exists a, In a l /\ check_dest a r = true) -> *)
(*   check_dest_l l r = true. *)
(* Proof. *)
(*   induction l; crush. *)
(*   specialize (IHl r). inv H. *)
(*   apply orb_true_intro; crush. *)
(*   apply orb_true_intro; crush. *)
(*   right. apply IHl. exists x. auto. *)
(* Qed. *)

(* Lemma check_list_l_false : *)
(*   forall l x r, *)
(*   check_dest_l (l ++ x :: nil) r = false -> *)
(*   check_dest_l l r = false /\ check_dest x r = false. *)
(* Proof. *)
(*   simplify. *)
(*   apply check_dest_l_forall in H. apply Forall_app in H. *)
(*   simplify. apply check_dest_l_forall2; auto. *)
(*   apply check_dest_l_forall in H. apply Forall_app in H. *)
(*   simplify. inv H1. auto. *)
(* Qed. *)

(* Lemma check_dest_l_ex : *)
(*   forall l r, *)
(*   check_dest_l l r = true -> *)
(*   exists a, In a l /\ check_dest a r = true. *)
(* Proof. *)
(*   induction l; crush. *)
(*   destruct (check_dest a r) eqn:?; try solve [econstructor; crush]. *)
(*   simplify. *)
(*   exploit IHl. apply H. simplify. econstructor. simplify. right. eassumption. *)
(*   auto. *)
(* Qed. *)

(* Lemma check_list_l_true : *)
(*   forall l x r, *)
(*   check_dest_l (l ++ x :: nil) r = true -> *)
(*   check_dest_l l r = true \/ check_dest x r = true. *)
(* Proof. *)
(*   simplify. *)
(*   apply check_dest_l_ex in H; simplify. *)
(*   apply in_app_or in H. inv H. left. *)
(*   apply check_dest_l_ex2. exists x0. auto. *)
(*   inv H0; auto. *)
(* Qed. *)

(* Lemma check_dest_l_dec2 l r : *)
(*   {Forall (fun x => check_dest x r = false) l} *)
(*   + {exists a, In a l /\ check_dest a r = true}. *)
(* Proof. *)
(*   destruct (check_dest_l_dec l r); [right | left]; *)
(*   auto using check_dest_l_ex, check_dest_l_forall. *)
(* Qed. *)

(* Lemma abstr_comp : *)
(*   forall l i f x x0, *)
(*   fold_left update (l ++ i :: nil) f = x -> *)
(*   fold_left update l f = x0 -> *)
(*   x = update x0 i. *)
(* Proof. induction l; intros; crush; eapply IHl; eauto. Qed. *)

(*

Lemma gen_list_base:
  forall FF ge sp l rs exps st1,
  (forall x, @sem_value FF ge sp st1 (exps # (Reg x)) (rs !! x)) ->
  sem_val_list ge sp st1 (list_translation l exps) rs ## l.
Proof.
  induction l.
  intros. simpl. constructor.
  intros. simpl. eapply Scons; eauto.
Qed.

Lemma check_dest_update2 :
  forall f r rl op p,
  (update f (RBop p op rl r)) # (Reg r) = Eop op (list_translation rl f) (f # Mem).
Proof. crush; rewrite map2; auto. Qed.

Lemma check_dest_update3 :
  forall f r rl p addr chunk,
  (update f (RBload p chunk addr rl r)) # (Reg r) = Eload chunk addr (list_translation rl f) (f # Mem).
Proof. crush; rewrite map2; auto. Qed.

Lemma abstract_seq_correct_aux:
  forall FF ge sp i st1 st2 st3 f,
    @step_instr FF ge sp st3 i st2 ->
    sem ge sp st1 f st3 ->
    sem ge sp st1 (update f i) st2.
Proof.
  intros; inv H; simplify.
  { simplify; eauto. } (*apply match_states_refl. }*)
  { inv H0. inv H6. destruct st1. econstructor. simplify.
    constructor. intros.
    destruct (resource_eq (Reg res) (Reg x)). inv e.
    rewrite map2. econstructor. eassumption. apply gen_list_base; eauto.
    rewrite Regmap.gss. eauto.
    assert (res <> x). { unfold not in *. intros. apply n. rewrite H0. auto. }
    rewrite Regmap.gso by auto.
    rewrite genmap1 by auto. auto.

    rewrite genmap1; crush. }
  { inv H0. inv H7. constructor. constructor. intros.
    destruct (Pos.eq_dec dst x); subst.
    rewrite map2. econstructor; eauto.
    apply gen_list_base. auto. rewrite Regmap.gss. auto.
    rewrite genmap1. rewrite Regmap.gso by auto. auto.
    unfold not in *; intros. inv H0. auto.
    rewrite genmap1; crush.
  }
  { inv H0. inv H7. constructor. constructor; intros.
    rewrite genmap1; crush.
    rewrite map2. econstructor; eauto.
    apply gen_list_base; auto.
  }
Qed.

Lemma regmap_list_equiv :
  forall A (rs1: Regmap.t A) rs2,
    (forall x, rs1 !! x = rs2 !! x) ->
    forall rl, rs1##rl = rs2##rl.
Proof. induction rl; crush. Qed.

Lemma sem_update_Op :
  forall A ge sp st f st' r l o0 o m rs v,
  @sem A ge sp st f st' ->
  Op.eval_operation ge sp o0 rs ## l m = Some v ->
  match_states st' (mk_instr_state rs m) ->
  exists tst,
  sem ge sp st (update f (RBop o o0 l r)) tst /\ match_states (mk_instr_state (Regmap.set r v rs) m) tst.
Proof.
  intros. inv H1. simplify.
  destruct st.
  econstructor. simplify.
  { constructor.
    { constructor. intros. destruct (Pos.eq_dec x r); subst.
      { pose proof (H5 r). rewrite map2. pose proof H. inv H. econstructor; eauto.
        { inv H9. eapply gen_list_base; eauto. }
        { instantiate (1 := (Regmap.set r v rs0)). rewrite Regmap.gss. erewrite regmap_list_equiv; eauto. } }
      { rewrite Regmap.gso by auto. rewrite genmap1; crush. inv H. inv H7; eauto. } }
    { inv H. rewrite genmap1; crush. eauto. } }
  { constructor; eauto. intros.
    destruct (Pos.eq_dec r x);
    subst; [repeat rewrite Regmap.gss | repeat rewrite Regmap.gso]; auto. }
Qed.

Lemma sem_update_load :
  forall A ge sp st f st' r o m a l m0 rs v a0,
  @sem A ge sp st f st' ->
  Op.eval_addressing ge sp a rs ## l = Some a0 ->
  Mem.loadv m m0 a0 = Some v ->
  match_states st' (mk_instr_state rs m0) ->
  exists tst : instr_state,
    sem ge sp st (update f (RBload o m a l r)) tst
    /\ match_states (mk_instr_state (Regmap.set r v rs) m0) tst.
Proof.
  intros. inv H2. pose proof H. inv H. inv H9.
  destruct st.
  econstructor; simplify.
  { constructor.
    { constructor. intros.
      destruct (Pos.eq_dec x r); subst.
      { rewrite map2. econstructor; eauto. eapply gen_list_base. intros.
        rewrite <- H6. eauto.
        instantiate (1 := (Regmap.set r v rs0)). rewrite Regmap.gss. auto. }
      { rewrite Regmap.gso by auto. rewrite genmap1; crush. } }
    { rewrite genmap1; crush. eauto. } }
  { constructor; auto; intros. destruct (Pos.eq_dec r x);
    subst; [repeat rewrite Regmap.gss | repeat rewrite Regmap.gso]; auto. }
Qed.

Lemma sem_update_store :
  forall A ge sp a0 m a l r o f st m' rs m0 st',
  @sem A ge sp st f st' ->
  Op.eval_addressing ge sp a rs ## l = Some a0 ->
  Mem.storev m m0 a0 rs !! r = Some m' ->
  match_states st' (mk_instr_state rs m0) ->
  exists tst, sem ge sp st (update f (RBstore o m a l r)) tst
              /\ match_states (mk_instr_state rs m') tst.
Proof.
  intros. inv H2. pose proof H. inv H. inv H9.
  destruct st.
  econstructor; simplify.
  { econstructor.
    { econstructor; intros. rewrite genmap1; crush. }
    { rewrite map2. econstructor; eauto. eapply gen_list_base. intros. rewrite <- H6.
      eauto. specialize (H6 r). rewrite H6. eauto. } }
  { econstructor; eauto. }
Qed.

Lemma sem_update :
  forall A ge sp st x st' st'' st''' f,
  sem ge sp st f st' ->
  match_states st' st''' ->
  @step_instr A ge sp st''' x st'' ->
  exists tst, sem ge sp st (update f x) tst /\ match_states st'' tst.
Proof.
  intros. destruct x; inv H1.
  { econstructor. split.
    apply sem_update_RBnop. eassumption.
    apply match_states_commut. auto. }
  { eapply sem_update_Op; eauto. }
  { eapply sem_update_load; eauto. }
  { eapply sem_update_store; eauto. }
Qed.

Lemma sem_update2_Op :
  forall A ge sp st f r l o0 o m rs v,
  @sem A ge sp st f (mk_instr_state rs m) ->
  Op.eval_operation ge sp o0 rs ## l m = Some v ->
  sem ge sp st (update f (RBop o o0 l r)) (mk_instr_state (Regmap.set r v rs) m).
Proof.
  intros. destruct st. constructor.
  inv H. inv H6.
  { constructor; intros. simplify.
    destruct (Pos.eq_dec r x); subst.
    { rewrite map2. econstructor. eauto.
      apply gen_list_base. eauto.
      rewrite Regmap.gss. auto. }
    { rewrite genmap1; crush. rewrite Regmap.gso; auto.  } }
  { simplify. rewrite genmap1; crush. inv H. eauto. }
Qed.

Lemma sem_update2_load :
  forall A ge sp st f r o m a l m0 rs v a0,
    @sem A ge sp st f (mk_instr_state rs m0) ->
    Op.eval_addressing ge sp a rs ## l = Some a0 ->
    Mem.loadv m m0 a0 = Some v ->
    sem ge sp st (update f (RBload o m a l r)) (mk_instr_state (Regmap.set r v rs) m0).
Proof.
  intros. simplify. inv H. inv H7. constructor.
  { constructor; intros. destruct (Pos.eq_dec r x); subst.
    { rewrite map2. rewrite Regmap.gss. econstructor; eauto.
      apply gen_list_base; eauto. }
    { rewrite genmap1; crush. rewrite Regmap.gso; eauto. }
  }
  { simplify. rewrite genmap1; crush. }
Qed.

Lemma sem_update2_store :
  forall A ge sp a0 m a l r o f st m' rs m0,
    @sem A ge sp st f (mk_instr_state rs m0) ->
    Op.eval_addressing ge sp a rs ## l = Some a0 ->
    Mem.storev m m0 a0 rs !! r = Some m' ->
    sem ge sp st (update f (RBstore o m a l r)) (mk_instr_state rs m').
Proof.
  intros. simplify. inv H. inv H7. constructor; simplify.
  { econstructor; intros. rewrite genmap1; crush. }
  { rewrite map2. econstructor; eauto. apply gen_list_base; eauto. }
Qed.

Lemma sem_update2 :
  forall A ge sp st x st' st'' f,
  sem ge sp st f st' ->
  @step_instr A ge sp st' x st'' ->
  sem ge sp st (update f x) st''.
Proof.
  intros.
  destruct x; inv H0;
  eauto using sem_update_RBnop, sem_update2_Op, sem_update2_load, sem_update2_store.
Qed.

Lemma abstr_sem_val_mem :
  forall A B ge tge st tst sp a,
    ge_preserved ge tge ->
    forall v m,
    (@sem_mem A ge sp st a m /\ match_states st tst -> @sem_mem B tge sp tst a m) /\
    (@sem_value A ge sp st a v /\ match_states st tst -> @sem_value B tge sp tst a v).
Proof.
  intros * H.
  apply expression_ind2 with

    (P := fun (e1: expression) =>
    forall v m,
    (@sem_mem A ge sp st e1 m /\ match_states st tst -> @sem_mem B tge sp tst e1 m) /\
    (@sem_value A ge sp st e1 v /\ match_states st tst -> @sem_value B tge sp tst e1 v))

    (P0 := fun (e1: expression_list) =>
    forall lv, @sem_val_list A ge sp st e1 lv /\ match_states st tst -> @sem_val_list B tge sp tst e1 lv);
  simplify; intros; simplify.
  { inv H1. inv H2. constructor. }
  { inv H2. inv H1. rewrite H0. constructor. }
  { inv H3. }
  { inv H3. inv H4. econstructor. apply H1; auto. simplify. eauto. constructor. auto. auto.
    apply H0; simplify; eauto. constructor; eauto.
    unfold ge_preserved in *. simplify. rewrite <- H2. auto.
  }
  { inv H3. }
  { inv H3. inv H4. econstructor. apply H1; eauto; simplify; eauto. constructor; eauto.
    apply H0; simplify; eauto. constructor; eauto.
    inv H. rewrite <- H4. eauto.
    auto.
  }
  { inv H4. inv H5. econstructor. apply H0; eauto. simplify; eauto. constructor; eauto.
    apply H2; eauto. simplify; eauto. constructor; eauto.
    apply H1; eauto. simplify; eauto. constructor; eauto.
    inv H. rewrite <- H5. eauto. auto.
  }
  { inv H4. }
  { inv H1. constructor. }
  { inv H3. constructor; auto. apply H0; eauto. apply Mem.empty. }
Qed.

Lemma abstr_sem_value :
  forall a A B ge tge sp st tst v,
    @sem_value A ge sp st a v ->
    ge_preserved ge tge ->
    match_states st tst ->
    @sem_value B tge sp tst a v.
Proof. intros; eapply abstr_sem_val_mem; eauto; apply Mem.empty. Qed.

Lemma abstr_sem_mem :
  forall a A B ge tge sp st tst v,
    @sem_mem A ge sp st a v ->
    ge_preserved ge tge ->
    match_states st tst ->
    @sem_mem B tge sp tst a v.
Proof. intros; eapply abstr_sem_val_mem; eauto. Qed.

Lemma abstr_sem_regset :
  forall a a' A B ge tge sp st tst rs,
    @sem_regset A ge sp st a rs ->
    ge_preserved ge tge ->
    (forall x, a # x = a' # x) ->
    match_states st tst ->
    exists rs', @sem_regset B tge sp tst a' rs' /\ (forall x, rs !! x = rs' !! x).
Proof.
  inversion 1; intros.
  inv H7.
  econstructor. simplify. econstructor. intros.
  eapply abstr_sem_value; eauto. rewrite <- H6.
  eapply H0. constructor; eauto.
  auto.
Qed.

Lemma abstr_sem :
  forall a a' A B ge tge sp st tst st',
    @sem A ge sp st a st' ->
    ge_preserved ge tge ->
    (forall x, a # x = a' # x) ->
    match_states st tst ->
    exists tst', @sem B tge sp tst a' tst' /\ match_states st' tst'.
Proof.
  inversion 1; subst; intros.
  inversion H4; subst.
  exploit abstr_sem_regset; eauto; inv_simp.
  do 3 econstructor; eauto.
  rewrite <- H3.
  eapply abstr_sem_mem; eauto.
Qed.

Lemma abstract_execution_correct':
  forall A B ge tge sp st' a a' st tst,
  @sem A ge sp st a st' ->
  ge_preserved ge tge ->
  check a a' = true ->
  match_states st tst ->
  exists tst', @sem B tge sp tst a' tst' /\ match_states st' tst'.
Proof.
  intros;
  pose proof (check_correct a a' H1);
  eapply abstr_sem; eauto.
Qed.

Lemma states_match :
  forall st1 st2 st3 st4,
  match_states st1 st2 ->
  match_states st2 st3 ->
  match_states st3 st4 ->
  match_states st1 st4.
Proof.
  intros * H1 H2 H3; destruct st1; destruct st2; destruct st3; destruct st4.
  inv H1. inv H2. inv H3; constructor.
  unfold regs_lessdef in *. intros.
  repeat match goal with
         | H: forall _, _, r : positive |- _ => specialize (H r)
         end.
  congruence.
  auto.
Qed.

Lemma step_instr_block_same :
  forall ge sp st st',
  step_instr_block ge sp st nil st' ->
  st = st'.
Proof. inversion 1; auto. Qed.

Lemma step_instr_seq_same :
  forall ge sp st st',
  step_instr_seq ge sp st nil st' ->
  st = st'.
Proof. inversion 1; auto. Qed.

Lemma sem_update' :
  forall A ge sp st a x st',
  sem ge sp st (update (abstract_sequence empty a) x) st' ->
  exists st'',
  @step_instr A ge sp st'' x st' /\
  sem ge sp st (abstract_sequence empty a) st''.
Proof.
  Admitted.

Lemma rtlpar_trans_correct :
  forall bb ge sp sem_st' sem_st st,
  sem ge sp sem_st (abstract_sequence empty (concat (concat bb))) sem_st' ->
  match_states sem_st st ->
  exists st', RTLPar.step_instr_block ge sp st bb st'
              /\ match_states sem_st' st'.
Proof.
  induction bb using rev_ind.
  { repeat econstructor. eapply abstract_interp_empty3 in H.
    inv H. inv H0. constructor; congruence. }
  { simplify. inv H0. repeat rewrite concat_app in H. simplify.
    rewrite app_nil_r in H.
    exploit sem_separate; eauto; inv_simp.
    repeat econstructor. admit. admit.
  }
Admitted.

(*Lemma abstract_execution_correct_ld:
  forall bb bb' cfi ge tge sp st st' tst,
    RTLBlock.step_instr_list ge sp st bb st' ->
    ge_preserved ge tge ->
    schedule_oracle (mk_bblock bb cfi) (mk_bblock bb' cfi) = true ->
    match_states_ld st tst ->
    exists tst', RTLPar.step_instr_block tge sp tst bb' tst'
                 /\ match_states st' tst'.
Proof.
  intros.*)
*)

Lemma match_states_list :
  forall A (rs: Regmap.t A) rs',
  (forall r, rs !! r = rs' !! r) ->
  forall l, rs ## l = rs' ## l.
Proof. induction l; crush. Qed.

Lemma PTree_matches :
  forall A (v: A) res rs rs',
  (forall r, rs !! r = rs' !! r) ->
  forall x, (Regmap.set res v rs) !! x = (Regmap.set res v rs') !! x.
Proof.
  intros; destruct (Pos.eq_dec x res); subst;
  [ repeat rewrite Regmap.gss by auto
  | repeat rewrite Regmap.gso by auto ]; auto.
Qed.

(*Lemma abstract_interp_empty3 :
  forall A ctx st',
    @sem A ctx empty st' -> match_states (ctx_is ctx) st'.
Proof.
  inversion 1; subst; simplify. destruct ctx.
  destruct ctx_is.
  constructor; intros.
  - inv H0. specialize (H3 x). inv H3. inv H8. reflexivity.
  - inv H1. specialize (H3 x). inv H3. inv H8. reflexivity.
  - inv H2. inv H8. reflexivity.
Qed.

Lemma step_instr_matches :
  forall A a ge sp st st',
    @step_instr A ge sp st a st' ->
    forall tst,
      match_states st tst ->
      exists tst', step_instr ge sp tst a tst'
                   /\ match_states st' tst'.
Proof.
  induction 1; simplify;
  match goal with H: match_states _ _ |- _ => inv H end;
  try solve [repeat econstructor; try erewrite match_states_list;
  try apply PTree_matches; eauto;
  match goal with
    H: forall _, _ |- context[Mem.storev] => erewrite <- H; eauto
  end].
  - destruct p. match goal with H: eval_pred _ _ _ _ |- _ => inv H end.
    repeat econstructor; try erewrite match_states_list; eauto.
    erewrite <- eval_predf_pr_equiv; eassumption.
    apply PTree_matches; assumption.
    repeat (econstructor; try apply eval_pred_false); eauto. try erewrite match_states_list; eauto.
    erewrite <- eval_predf_pr_equiv; eassumption.
    econstructor; auto.
    match goal with H: eval_pred _ _ _ _ |- _ => inv H end.
    repeat econstructor; try erewrite match_states_list; eauto.
  (*- destruct p. match goal with H: eval_pred _ _ _ _ |- _ => inv H end.
    repeat econstructor; try erewrite match_states_list; eauto.
    erewrite <- eval_predf_pr_equiv; eassumption.
    apply PTree_matches; assumption.
    repeat (econstructor; try apply eval_pred_false); eauto. try erewrite match_states_list; eauto.
    erewrite <- eval_predf_pr_equiv; eassumption.
    econstructor; auto.
    match goal with H: eval_pred _ _ _ _ |- _ => inv H end.
    repeat econstructor; try erewrite match_states_list; eauto.
  - destruct p. match goal with H: eval_pred _ _ _ _ |- _ => inv H end.
    repeat econstructor; try erewrite match_states_list; eauto.
    match goal with
    H: forall _, _ |- context[Mem.storev] => erewrite <- H; eauto
    end.
    erewrite <- eval_predf_pr_equiv; eassumption.
    repeat (econstructor; try apply eval_pred_false); eauto. try erewrite match_states_list; eauto.
    match goal with
    H: forall _, _ |- context[Mem.storev] => erewrite <- H; eauto
    end.
    erewrite <- eval_predf_pr_equiv; eassumption.
    match goal with H: eval_pred _ _ _ _ |- _ => inv H end.
    repeat econstructor; try erewrite match_states_list; eauto.
    match goal with
    H: forall _, _ |- context[Mem.storev] => erewrite <- H; eauto
    end.
  - admit.*) Admitted.

Lemma step_instr_list_matches :
  forall a ge sp st st',
  step_instr_list ge sp st a st' ->
  forall tst, match_states st tst ->
              exists tst', step_instr_list ge sp tst a tst'
                           /\ match_states st' tst'.
Proof.
  induction a; intros; inv H;
  try (exploit step_instr_matches; eauto; []; simplify;
       exploit IHa; eauto; []; simplify); repeat econstructor; eauto.
Qed.

Lemma step_instr_seq_matches :
  forall a ge sp st st',
   step_instr_seq ge sp st a st' ->
  forall tst, match_states st tst ->
              exists tst', step_instr_seq ge sp tst a tst'
                           /\ match_states st' tst'.
Proof.
  induction a; intros; inv H;
  try (exploit step_instr_list_matches; eauto; []; simplify;
       exploit IHa; eauto; []; simplify); repeat econstructor; eauto.
Qed.

Lemma step_instr_block_matches :
  forall bb ge sp st st',
  step_instr_block ge sp st bb st' ->
  forall tst, match_states st tst ->
              exists tst', step_instr_block ge sp tst bb tst'
                           /\ match_states st' tst'.
Proof.
  induction bb; intros; inv H;
  try (exploit step_instr_seq_matches; eauto; []; simplify;
       exploit IHbb; eauto; []; simplify); repeat econstructor; eauto.
Qed.

Lemma rtlblock_trans_correct' :
  forall bb ge sp st x st'',
  RTLBlock.step_instr_list ge sp st (bb ++ x :: nil) st'' ->
  exists st', RTLBlock.step_instr_list ge sp st bb st'
              /\ step_instr ge sp st' x st''.
Proof.
  induction bb.
  crush. exists st.
  split. constructor. inv H. inv H6. auto.
  crush. inv H. exploit IHbb. eassumption. simplify.
  econstructor. split.
  econstructor; eauto. eauto.
Qed.

Lemma abstract_interp_empty A st : @sem A st empty (ctx_is st).
Proof. destruct st, ctx_is. simpl. repeat econstructor. Qed.

Lemma abstract_seq :
  forall l f i,
    abstract_sequence f (l ++ i :: nil) = update (abstract_sequence f l) i.
Proof. induction l; crush. Qed.

Lemma abstract_sequence_update :
  forall l r f,
  check_dest_l l r = false ->
  (abstract_sequence f l) # (Reg r) = f # (Reg r).
Proof.
  induction l using rev_ind; crush.
  rewrite abstract_seq. rewrite check_dest_update. apply IHl.
  apply check_list_l_false in H. tauto.
  apply check_list_l_false in H. tauto.
Qed.

(*Lemma sem_separate :
  forall A ctx b a st',
    sem ctx (abstract_sequence empty (a ++ b)) st' ->
    exists st'',
         @sem A ctx (abstract_sequence empty a) st''
      /\ @sem A (mk_ctx st'' (ctx_sp ctx) (ctx_ge ctx)) (abstract_sequence empty b) st'.
Proof.
  induction b using rev_ind; simplify.
  { econstructor. simplify. rewrite app_nil_r in H. eauto. apply abstract_interp_empty. }
  { simplify. rewrite app_assoc in H. rewrite abstract_seq in H.
    exploit sem_update'; eauto; simplify.
    exploit IHb; eauto; inv_simp.
    econstructor; split; eauto.
    rewrite abstract_seq.
    eapply sem_update2; eauto.
  }
Qed.*)

Lemma sem_update_RBnop :
  forall A ctx f st',
  @sem A ctx f st' -> sem ctx (update f RBnop) st'.
Proof. auto. Qed.

Lemma sem_update_Op :
  forall A ge sp ist f st' r l o0 o m rs v ps,
  @sem A (mk_ctx ist sp ge) f st' ->
  eval_predf ps o = true ->
  Op.eval_operation ge sp o0 (rs ## l) m = Some v ->
  match_states st' (mk_instr_state rs ps m) ->
  exists tst,
  sem (mk_ctx ist sp ge) (update f (RBop (Some o) o0 l r)) tst
  /\ match_states (mk_instr_state (Regmap.set r v rs) ps m) tst.
Proof.
  intros. inv H1. inv H. inv H1. inv H3. simplify.
  econstructor. simplify.
  { constructor; try constructor; intros; try solve [rewrite genmap1; now eauto].
    destruct (Pos.eq_dec x r); subst.
    { rewrite map2. specialize (H1 r). inv H1.
(*}
  }
  destruct st.
  econstructor. simplify.
  { constructor.
    { constructor. intros. destruct (Pos.eq_dec x r); subst.
      { pose proof (H5 r). rewrite map2. pose proof H. inv H. econstructor; eauto.
        { inv H9. eapply gen_list_base; eauto. }
        { instantiate (1 := (Regmap.set r v rs0)). rewrite Regmap.gss. erewrite regmap_list_equiv; eauto. } }
      { rewrite Regmap.gso by auto. rewrite genmap1; crush. inv H. inv H7; eauto. } }
    { inv H. rewrite genmap1; crush. eauto. } }
  { constructor; eauto. intros.
    destruct (Pos.eq_dec r x);
    subst; [repeat rewrite Regmap.gss | repeat rewrite Regmap.gso]; auto. }
Qed.*) Admitted.

Lemma sem_update :
  forall A ge sp st x st' st'' st''' f,
  sem (mk_ctx st sp ge) f st' ->
  match_states st' st''' ->
  @step_instr A ge sp st''' x st'' ->
  exists tst, sem (mk_ctx st sp ge) (update f x) tst /\ match_states st'' tst.
Proof.
  intros. destruct x.
  - inv H1. econstructor. simplify. eauto. symmetry; auto.
  - inv H1. inv H0. econstructor.
    Admitted.

Lemma rtlblock_trans_correct :
  forall bb ge sp st st',
    RTLBlock.step_instr_list ge sp st bb st' ->
    forall tst,
      match_states st tst ->
      exists tst', sem (mk_ctx tst sp ge) (abstract_sequence empty bb) tst'
                   /\ match_states st' tst'.
Proof.
  induction bb using rev_ind; simplify.
  { econstructor. simplify. apply abstract_interp_empty.
    inv H. auto. }
  { apply rtlblock_trans_correct' in H. simplify.
    rewrite abstract_seq.
    exploit IHbb; try eassumption; []; simplify.
    exploit sem_update. apply H1. symmetry; eassumption.
    eauto. simplify. econstructor. split. apply H3.
    auto. }
Qed.

Lemma abstract_execution_correct:
  forall bb bb' cfi cfi' ge tge sp st st' tst,
    RTLBlock.step_instr_list ge sp st bb st' ->
    ge_preserved ge tge ->
    schedule_oracle (mk_bblock bb cfi) (mk_bblock bb' cfi') = true ->
    match_states st tst ->
    exists tst', RTLPar.step_instr_block tge sp tst bb' tst'
                 /\ match_states st' tst'.
Proof.
  intros.
  unfold schedule_oracle in *. simplify. unfold empty_trees in H4.
  exploit rtlblock_trans_correct; try eassumption; []; simplify.
(*)  exploit abstract_execution_correct';
  try solve [eassumption | apply state_lessdef_match_sem; eassumption].
  apply match_states_commut. eauto. inv_simp.
  exploit rtlpar_trans_correct; try eassumption; []; inv_simp.
  exploit step_instr_block_matches; eauto. apply match_states_commut; eauto. inv_simp.
  repeat match goal with | H: match_states _ _ |- _ => inv H end.
  do 2 econstructor; eauto.
  econstructor; congruence.
Qed.*)Admitted.*)

Definition match_prog (prog : GibleSeq.program) (tprog : GiblePar.program) :=
  match_program (fun cu f tf => transl_fundef f = Errors.OK tf) eq prog tprog.

(* TODO: Fix the `bb` and add matches for them. *)
Inductive match_stackframes: GibleSeq.stackframe -> GiblePar.stackframe -> Prop :=
| match_stackframe:
    forall f tf res sp pc rs rs' ps ps',
      transl_function f = OK tf ->
      (forall x, rs !! x = rs' !! x) ->
      (forall x, ps !! x = ps' !! x) ->
      match_stackframes (GibleSeq.Stackframe res f sp pc rs ps)
                        (Stackframe res tf sp pc rs' ps').

Inductive match_states: GibleSeq.state -> GiblePar.state -> Prop :=
| match_state:
    forall sf f sp pc rs rs' m sf' tf ps ps'
      (TRANSL: transl_function f = OK tf)
      (STACKS: list_forall2 match_stackframes sf sf')
      (REG: forall x, rs !! x = rs' !! x)
      (REG: forall x, ps !! x = ps' !! x),
      match_states (GibleSeq.State sf f sp pc rs ps m)
                   (State sf' tf sp pc rs' ps' m)
| match_returnstate:
    forall stack stack' v m
      (STACKS: list_forall2 match_stackframes stack stack'),
      match_states (GibleSeq.Returnstate stack v m)
                   (Returnstate stack' v m)
| match_callstate:
    forall stack stack' f tf args m
      (TRANSL: transl_fundef f = OK tf)
      (STACKS: list_forall2 match_stackframes stack stack'),
      match_states (GibleSeq.Callstate stack f args m)
                   (Callstate stack' tf args m).

Section CORRECTNESS.

  Context (prog: GibleSeq.program) (tprog : GiblePar.program).
  Context (TRANSL: match_prog prog tprog).

  Let ge : GibleSeq.genv := Globalenvs.Genv.globalenv prog.
  Let tge : GiblePar.genv := Globalenvs.Genv.globalenv tprog.

  Lemma symbols_preserved:
    forall (s: AST.ident), Genv.find_symbol tge s = Genv.find_symbol ge s.
  Proof using TRANSL. intros. eapply (Genv.find_symbol_match TRANSL). Qed.
  Hint Resolve symbols_preserved : rtlgp.

  Lemma function_ptr_translated:
    forall (b: Values.block) (f: GibleSeq.fundef),
      Genv.find_funct_ptr ge b = Some f ->
      exists tf,
        Genv.find_funct_ptr tge b = Some tf /\ transl_fundef f = Errors.OK tf.
  Proof using TRANSL.
    intros. exploit (Genv.find_funct_ptr_match TRANSL); eauto.
    intros (cu & tf & P & Q & R); exists tf; auto.
  Qed.

  Lemma functions_translated:
    forall (v: Values.val) (f: GibleSeq.fundef),
      Genv.find_funct ge v = Some f ->
      exists tf,
        Genv.find_funct tge v = Some tf /\ transl_fundef f = Errors.OK tf.
  Proof using TRANSL.
    intros. exploit (Genv.find_funct_match TRANSL); eauto.
    intros (cu & tf & P & Q & R); exists tf; auto.
  Qed.

  Lemma senv_preserved:
    Senv.equiv (Genv.to_senv ge) (Genv.to_senv tge).
  Proof (Genv.senv_transf_partial TRANSL).
  Hint Resolve senv_preserved : rtlgp.

  Lemma sig_transl_function:
    forall (f: GibleSeq.fundef) (tf: GiblePar.fundef),
      transl_fundef f = OK tf ->
      funsig tf = GibleSeq.funsig f.
  Proof using .
    unfold transl_fundef, transf_partial_fundef, transl_function; intros;
    repeat destruct_match; crush;
    match goal with H: OK _ = OK _ |- _ => inv H end; auto.
  Qed.
  Hint Resolve sig_transl_function : rtlgp.

  Hint Resolve Val.lessdef_same : rtlgp.
  Hint Resolve regs_lessdef_regs : rtlgp.

  Lemma find_function_translated:
    forall ros rs rs' f,
      (forall x, rs !! x = rs' !! x) ->
      GibleSeq.find_function ge ros rs = Some f ->
      exists tf, find_function tge ros rs' = Some tf
                 /\ transl_fundef f = OK tf.
  Proof using TRANSL.
    Ltac ffts := match goal with
                 | [ H: forall _, Val.lessdef _ _, r: Registers.reg |- _ ] =>
                   specialize (H r); inv H
                 | [ H: Vundef = ?r, H1: Genv.find_funct _ ?r = Some _ |- _ ] =>
                   rewrite <- H in H1
                 | [ H: Genv.find_funct _ Vundef = Some _ |- _] => solve [inv H]
                 | _ => solve [exploit functions_translated; eauto]
                 end.
    destruct ros; simplify; try rewrite <- H;
    [| rewrite symbols_preserved; destruct_match;
      try (apply function_ptr_translated); crush ];
    intros;
    repeat ffts.
  Qed.

  Lemma schedule_oracle_nil:
    forall bb,
      schedule_oracle nil bb = true ->
      bb = nil.
  Proof using .
    unfold schedule_oracle, check_control_flow_instr.
    simplify; repeat destruct_match; crush.
  Qed.

  Lemma schedule_oracle_nil2:
      schedule_oracle nil nil = true.
  Proof using .
    unfold schedule_oracle, check_control_flow_instr.
    simplify; repeat destruct_match; crush.
  Admitted.

  Lemma eval_op_eq:
    forall (sp0 : Values.val) (op : Op.operation) (vl : list Values.val) m,
      Op.eval_operation ge sp0 op vl m = Op.eval_operation tge sp0 op vl m.
  Proof using TRANSL.
    intros.
    destruct op; auto; unfold Op.eval_operation, Genv.symbol_address, Op.eval_addressing32;
    [| destruct a; unfold Genv.symbol_address ];
    try rewrite symbols_preserved; auto.
  Qed.
  Hint Resolve eval_op_eq : rtlgp.

  Lemma eval_addressing_eq:
    forall sp addr vl,
      Op.eval_addressing ge sp addr vl = Op.eval_addressing tge sp addr vl.
  Proof using TRANSL.
    intros.
    destruct addr;
    unfold Op.eval_addressing, Op.eval_addressing32;
    unfold Genv.symbol_address;
    try rewrite symbols_preserved; auto.
  Qed.
  Hint Resolve eval_addressing_eq : rtlgp.

  Lemma ge_preserved_lem:
    ge_preserved ge tge.
  Proof using TRANSL.
    unfold ge_preserved.
    eauto with rtlgp.
  Qed.
  Hint Resolve ge_preserved_lem : rtlgp.

  Lemma lessdef_regmap_optget:
    forall or rs rs',
      regs_lessdef rs rs' ->
      Val.lessdef (regmap_optget or Vundef rs) (regmap_optget or Vundef rs').
  Proof using. destruct or; crush. Qed.
  Hint Resolve lessdef_regmap_optget : rtlgp.

  Lemma regmap_equiv_lessdef:
    forall rs rs',
      (forall x, rs !! x = rs' !! x) ->
      regs_lessdef rs rs'.
  Proof using.
    intros; unfold regs_lessdef; intros.
    rewrite H. apply Val.lessdef_refl.
  Qed.
  Hint Resolve regmap_equiv_lessdef : rtlgp.

  Lemma int_lessdef:
    forall rs rs',
      regs_lessdef rs rs' ->
      (forall arg v,
          rs !! arg = Vint v ->
          rs' !! arg = Vint v).
  Proof using. intros ? ? H; intros; specialize (H arg); inv H; crush. Qed.
  Hint Resolve int_lessdef : rtlgp.

  Ltac semantics_simpl :=
    match goal with
    | [ H: match_states _ _ |- _ ] =>
      let H2 := fresh "H" in
      learn H as H2; inv H2
    | [ H: transl_function ?f = OK _ |- _ ] =>
      let H2 := fresh "TRANSL" in
      learn H as H2;
      unfold transl_function in H2;
      destruct (check_scheduled_trees
                  (GibleSeq.fn_code f)
                  (fn_code (schedule f))) eqn:?;
               [| discriminate ]; inv H2
    | [ H: context[check_scheduled_trees] |- _ ] =>
      let H2 := fresh "CHECK" in
      learn H as H2;
      eapply check_scheduled_trees_correct in H2; [| solve [eauto] ]
    | [ H: schedule_oracle nil ?bb = true |- _ ] =>
      let H2 := fresh "SCHED" in
      learn H as H2;
      apply schedule_oracle_nil in H2
    | [ H: find_function _ _ _ = Some _, H2: forall x, ?rs !! x = ?rs' !! x |- _ ] =>
      learn H; exploit find_function_translated; try apply H2; eauto; inversion 1
    | [ H: Mem.free ?m _ _ _ = Some ?m', H2: Mem.extends ?m ?m'' |- _ ] =>
      learn H; exploit Mem.free_parallel_extends; eauto; intros
    | [ H: Events.eval_builtin_args _ _ _ _ _ _, H2: regs_lessdef ?rs ?rs' |- _ ] =>
      let H3 := fresh "H" in
      learn H; exploit Events.eval_builtin_args_lessdef; [apply H2 | | |];
      eauto with rtlgp; intro H3; learn H3
    | [ H: Events.external_call _ _ _ _ _ _ _ |- _ ] =>
      let H2 := fresh "H" in
      learn H; exploit Events.external_call_mem_extends;
      eauto; intro H2; learn H2
    | [ H: exists _, _ |- _ ] => inv H
    | _ => progress simplify
    end.

  Hint Resolve Events.eval_builtin_args_preserved : rtlgp.
  Hint Resolve Events.external_call_symbols_preserved : rtlgp.
  Hint Resolve set_res_lessdef : rtlgp.
  Hint Resolve set_reg_lessdef : rtlgp.
  Hint Resolve Op.eval_condition_lessdef : rtlgp.

  Hint Constructors Events.eval_builtin_arg: barg.

  Lemma eval_builtin_arg_eq:
    forall A ge a v1 m1 e1 e2 sp,
      (forall x, e1 x = e2 x) ->
      @Events.eval_builtin_arg A ge e1 sp m1 a v1 ->
      Events.eval_builtin_arg ge e2 sp m1 a v1.
Proof. induction 2; try rewrite H; eauto with barg. Qed.

  Lemma eval_builtin_args_eq:
    forall A ge e1 sp m1 e2 al vl1,
      (forall x, e1 x = e2 x) ->
      @Events.eval_builtin_args A ge e1 sp m1 al vl1 ->
      Events.eval_builtin_args ge e2 sp m1 al vl1.
  Proof.
    induction 2.
    - econstructor; split.
    - exploit eval_builtin_arg_eq; eauto. intros.
      destruct IHlist_forall2 as [| y]. constructor; eauto.
      constructor. constructor; auto.
      constructor; eauto.
  Qed.

  #[local] Hint Resolve Events.external_call_symbols_preserved : core.
  #[local] Hint Resolve eval_builtin_args_eq : core.
  #[local] Hint Resolve symbols_preserved : core.
  #[local] Hint Resolve senv_preserved : core.
  #[local] Hint Resolve eval_op_eq : core.
  #[local] Hint Resolve eval_addressing_eq : core.

  Lemma step_instr_ge :
    forall sp a i i',
      step_instr ge sp i a i' ->
      step_instr tge sp i a i'.
  Proof.
    inversion 1; subst; simplify; try solve [econstructor; eauto].
    - constructor; auto; rewrite <- eval_op_eq; eauto.
    - econstructor; eauto; rewrite <- eval_addressing_eq; eauto.
    - econstructor; eauto; rewrite <- eval_addressing_eq; eauto.
  Qed.
  #[local] Hint Resolve step_instr_ge : core.

  Lemma seqbb_step_step_instr_list :
    forall sp a i i',
      SeqBB.step ge sp i a i' ->
      ParBB.step_instr_list tge sp i a i'.
  Proof.
    induction a; simplify; inv H.
    econstructor; eauto. eapply IHa; eauto.
    econstructor; eauto. constructor.
  Qed.
  #[local] Hint Resolve seqbb_step_step_instr_list : core.

  Lemma step_list2_step_instr_list :
    forall sp a i i',
      step_list2 (step_instr ge) sp i a i' ->
      ParBB.step_instr_list tge sp i a i'.
  Proof.
    induction a; simplify; inv H.
    econstructor; eauto.
    destruct i; try solve [inv H4].
    econstructor; eauto. apply IHa; auto.
  Qed.
  #[local] Hint Resolve step_list2_step_instr_list : core.

  Lemma seqbb_step_step_instr_seq :
    forall sp x i i' cf,
      SeqBB.step ge sp (Iexec i) (concat x) (Iterm i' cf) ->
      ParBB.step_instr_seq tge sp (Iexec i) x (Iterm i' cf).
  Proof.
    induction x; crush. inv H. eapply step_options in H.
    inv H. econstructor. eauto. constructor.
    simplify. econstructor; eauto.
    eapply IHx; eauto.
  Qed.

  Lemma step_list2_step_instr_seq :
    forall sp x i i',
      step_list2 (step_instr ge) sp (Iexec i) (concat x) (Iexec i') ->
      ParBB.step_instr_seq tge sp (Iexec i) x (Iexec i').
  Proof.
    induction x; crush. inv H. constructor.
    eapply step_options2 in H. simplify.
    econstructor; eauto.
    eapply IHx; eauto.
  Qed.

  Lemma seqbb_step_parbb_step :
    forall sp x i i' cf,
      SeqBB.step ge sp (Iexec i) (concat (concat x)) (Iterm i' cf) ->
      ParBB.step tge sp (Iexec i) x (Iterm i' cf).
  Proof.
    induction x; crush. inv H.
    rewrite concat_app in H.
    eapply step_options in H. inv H.
    constructor. eapply seqbb_step_step_instr_seq; eauto.
    simplify. econstructor.
    eapply step_list2_step_instr_seq; eauto.
    eapply IHx; eauto.
  Qed.

  Lemma eval_predf_negate :
    forall ps p,
      eval_predf ps (negate p) = negb (eval_predf ps p).
  Proof.
    unfold eval_predf; intros. rewrite negate_correct. auto.
  Qed.

  Lemma is_truthy_negate :
    forall ps p pred,
      truthy ps p ->
      falsy ps (combine_pred (Some (negate (Option.default T p))) pred).
  Proof.
    inversion 1; subst; simplify.
    - destruct pred; constructor; auto.
    - destruct pred; constructor.
      rewrite eval_predf_Pand. rewrite eval_predf_negate. rewrite H0. auto.
      rewrite eval_predf_negate. rewrite H0. auto.
  Qed.

  Lemma sem_update_instr :
    forall f i' i'' a sp p i p' f',
      sem (mk_ctx i sp ge) f (i', None) ->
      step_instr ge sp (Iexec i') a (Iexec i'') ->
      update (p, f) a = Some (p', f') ->
      sem (mk_ctx i sp ge) f' (i'', None).
  Proof. Admitted.


  Lemma sem_update_instr_term :
    forall f i' i'' a sp i cf p p' p'' f',
      sem (mk_ctx i sp ge) f (i', None) ->
      step_instr ge sp (Iexec i') (RBexit p cf) (Iterm i'' cf) ->
      update (p', f) a = Some (p'', f') ->
      sem (mk_ctx i sp ge) f' (i'', Some cf)
           /\ eval_predf (is_ps i) p'' = false.
  Proof.
    Admitted.

  (* Lemma step_instr_lessdef : *)
  (*   forall sp a i i' ti, *)
  (*     step_instr ge sp (Iexec i) a (Iexec i') -> *)
  (*     state_lessdef i ti -> *)
  (*     exists ti', step_instr ge sp (Iexec ti) a (Iexec ti') /\ state_lessdef i' ti'. *)
  (* Proof. Admitted. *)

  Lemma step_instr_lessdef_term :
    forall sp a i i' ti cf,
      step_instr ge sp (Iexec i) a (Iterm i' cf) ->
      state_lessdef i ti ->
      exists ti', step_instr ge sp (Iexec ti) a (Iterm ti' cf) /\ state_lessdef i' ti'.
  Proof. Admitted.

(*  Lemma app_predicated_semregset :
    forall A ctx o f res r y,
      @sem_regset A ctx f res ->
      falsy (ctx_ps ctx) o ->
      @sem_regset A ctx f # r <- (app_predicated o f#r y) res.
  Proof.
    inversion 1; subst; crush.
    constructor; intros.
    destruct (resource_eq r (Reg x)); subst.
    + rewrite map2; eauto. unfold app_predicated. inv H1. admit.
    + rewrite genmap1; auto.
  Admitted.

  Lemma app_predicated_sempredset :
    forall A ctx o f rs r y ps,
      @sem_predset A ctx f rs ->
      falsy ps o ->
      @sem_predset A ctx f # r <- (app_predicated o f#r y) rs.
  Proof. Admitted.

  Lemma app_predicated_sem :
    forall A ctx o f i cf r y,
      @sem A ctx f (i, cf) ->
      falsy (is_ps i) o ->
      @sem A ctx f # r <- (app_predicated o f#r y) (i, cf).
  Proof.
    inversion 1; subst; crush.
    constructor.
  Admitted.*)

  Lemma combined_falsy :
    forall i o1 o,
      falsy i o1 ->
      falsy i (combine_pred o o1).
  Proof.
    inversion 1; subst; crush. destruct o; simplify.
    constructor. rewrite eval_predf_Pand. rewrite H0. crush.
    constructor. auto.
  Qed.

  (* Inductive is_predicate_expr: expression -> Prop := *)
  (* | is_predicate_expr_Epredset : *)
  (*   forall c a, is_predicate_expr (Esetpred c a) *)
  (* | is_predicate_expr_Ebase : *)
  (*   forall p, is_predicate_expr (Ebase (Pred p)). *)

  (* Inductive apred_wf: apred_op -> Prop := *)
  (* | apred_wf_Plit: forall b p, *)
  (*     is_predicate_expr p -> *)
  (*     apred_wf (Plit (b, p)) *)
  (* | apred_wf_Ptrue: apred_wf Ptrue *)
  (* | apred_wf_Pfalse: apred_wf Pfalse *)
  (* | apred_wf_Pand: forall a b, *)
  (*   apred_wf a -> apred_wf b -> apred_wf (a ∧ b) *)
  (* | apred_wf_Por: forall a b, *)
  (*   apred_wf a -> apred_wf b -> apred_wf (a ∨ b). *)

  (* Lemma apred_and_false1 : *)
  (*   forall A ctx a b c, *)
  (*     @eval_apred A ctx a false -> *)
  (*     @eval_apred A ctx b c -> *)
  (*     eval_apred ctx (a ∧ b) false. *)
  (* Proof. *)
  (*   intros. *)
  (*   replace false with (false && c) by auto. *)
  (*   constructor; auto. *)
  (* Qed. *)

  (* Lemma apred_and_false2 : *)
  (*   forall A ctx a b c, *)
  (*     @eval_apred A ctx a c -> *)
  (*     eval_apred ctx b false -> *)
  (*     eval_apred ctx (a ∧ b) false. *)
  (* Proof. *)
  (*   intros. *)
  (*   replace false with (c && false) by eauto with bool. *)
  (*   constructor; auto. *)
  (* Qed. *)

  (* #[local] Opaque simplify. *)

  (* Lemma apred_simplify: *)
  (*   forall A ctx a b, *)
  (*     @eval_apred A ctx a b -> *)
  (*     @eval_apred A ctx (simplify a) b. *)
  (* Proof. Admitted. *)

  (* Lemma exists_get_pred_eval : *)
  (*   forall A ctx f p, *)
  (*   exists c, @eval_apred A ctx (get_pred' f p) c. *)
  (* Proof. *)
  (*   induction p; crush; try solve [econstructor; constructor; eauto]. *)
  (*   destruct_match. inv Heqp0. econstructor. *)
  (*   unfold apredicated_to_apred_op. *)
  (*   Admitted. (*probably not provable.*) *)

  (* Lemma falsy_update : *)
  (*   forall A f a ctx p f', *)
  (*     @eval_apred A ctx (fst f) false -> *)
  (*     update (Some f) a = Some (p, f') -> *)
  (*     eval_apred ctx p false. *)
  (* Proof. *)
  (*   destruct f; destruct a; inversion 1; subst; crush; *)
  (*   destruct_match; simplify; auto; *)
  (*   unfold Option.bind, Option.bind2 in *; *)
  (*   repeat (destruct_match; try discriminate; []); simplify; auto. *)
  (*   apply apred_simplify. eapply apred_and_false2; eauto. admit. *)
  (*   apply apred_simplify. eapply apred_and_false2; eauto. admit. *)
  (*   constructor; auto. *)
  (*   constructor; auto. *)
  (*   constructor; auto. *)
  (*   constructor; auto. *)
  (*   constructor; auto. *)
  (*   rewrite H2. *)
  (*   apply apred_simplify. eapply apred_and_false2; eauto. admit. *)
  (*   apply apred_simplify. eapply apred_and_false2; eauto. admit. *)
  (*   Unshelve. all: exact true. *)
  (* Admitted. *)

  (* Lemma abstr_fold_falsy : *)
  (*   forall x i0 sp cf i f p p' f', *)
  (*   sem (mk_ctx i0 sp ge) f (i, cf) -> *)
  (*   eval_apred (mk_ctx i0 sp ge) p false -> *)
  (*   fold_left update x (Some (p, f)) =  Some (p', f') -> *)
  (*   sem (mk_ctx i0 sp ge) f' (i, cf). *)
  (* Proof. *)
  (*   induction x; crush. *)
  (*   eapply IHx. *)
  (*   destruct a; destruct f; crush; *)
  (*     try solve [eapply app_predicated_sem; eauto; apply combined_falsy; auto]. *)
  (*   (* now apply falsy_update. *) *)
  (* (* Qed. *) Admitted. *)

  Lemma state_lessdef_sem :
    forall i sp f i' ti cf,
      sem (mk_ctx i sp ge) f (i', cf) ->
      state_lessdef i ti ->
      exists ti', sem (mk_ctx ti sp ge) f (ti', cf) /\ state_lessdef i' ti'.
  Proof. Admitted.

  (* #[local] Opaque update. *)

  Lemma abstr_fold_correct :
    forall sp x i i' i'' cf f p f',
      SeqBB.step ge sp (Iexec i') x (Iterm i'' cf) ->
      sem (mk_ctx i sp ge) (snd f) (i', None) ->
      mfold_left update x (Some f) = Some (p, f') ->
      forall ti,
        state_lessdef i ti ->
        exists ti', sem (mk_ctx ti sp ge) f' (ti', Some cf)
               /\ state_lessdef i'' ti'.
  Proof.
    induction x; simplify; inv H.
    - destruct f. (*  exploit update_Some; eauto; intros. simplify. *)
    (*   rewrite H3 in H1. destruct x0. *)
    (*   exploit IHx; eauto. eapply sem_update_instr; eauto. *)
    (* - destruct f. *)
    (*   exploit state_lessdef_sem; eauto; intros. simplify. *)
    (*   exploit step_instr_lessdef_term; eauto; intros. simplify. *)
    (*   inv H6. exploit update_Some; eauto; simplify. destruct x2. *)
      (* exploit sem_update_instr_term; eauto; simplify. *)
      (* eexists; split. *)
      (* eapply abstr_fold_falsy; eauto. *)
      (* rewrite H6 in H1. eauto. auto. *)
  (* Qed. *) Admitted.

  Lemma sem_regset_empty :
    forall A ctx, @sem_regset A ctx empty (ctx_rs ctx).
  Proof using.
    intros; constructor; intros.
    constructor; auto. constructor.
    constructor.
  Qed.

  Lemma sem_predset_empty :
    forall A ctx, @sem_predset A ctx empty (ctx_ps ctx).
  Proof using.
    intros; constructor; intros.
    constructor; auto. constructor.
  Qed.

  Lemma sem_empty :
    forall A ctx, @sem A ctx empty (ctx_is ctx, None).
  Proof using.
    intros. destruct ctx. destruct ctx_is.
    constructor; try solve [constructor; constructor; crush].
    eapply sem_regset_empty.
    eapply sem_predset_empty.
  Qed.

  Lemma abstr_sequence_correct :
    forall sp x i i'' cf x',
      SeqBB.step ge sp (Iexec i) x (Iterm i'' cf) ->
      abstract_sequence x = Some x' ->
      forall ti,
        state_lessdef i ti ->
        exists ti', sem (mk_ctx ti sp ge) x' (ti', Some cf)
               /\ state_lessdef i'' ti'.
  Proof.
    unfold abstract_sequence. intros. unfold Option.map in H0.
    destruct_match; try easy.
    destruct p; simplify.
    eapply abstr_fold_correct; eauto.
    simplify. eapply sem_empty.
  Qed.

  Lemma abstr_check_correct :
    forall sp i i' a b cf ti,
      check a b = true ->
      sem (mk_ctx i sp ge) a (i', cf) ->
      state_lessdef i ti ->
      exists ti', sem (mk_ctx ti sp ge) b (ti', cf)
             /\ state_lessdef i' ti'.
  Proof. Admitted.

  Lemma abstr_seq_reverse_correct :
    forall sp x i i' ti cf x',
      abstract_sequence x = Some x' ->
      sem (mk_ctx i sp ge) x' (i', (Some cf)) ->
      state_lessdef i ti ->
      exists ti', SeqBB.step ge sp (Iexec ti) x (Iterm ti' cf)
             /\ state_lessdef i' ti'.
  Proof. Admitted.

  Lemma schedule_oracle_correct :
    forall x y sp i i' ti cf,
      schedule_oracle x y = true ->
      SeqBB.step ge sp (Iexec i) x (Iterm i' cf) ->
      state_lessdef i ti ->
      exists ti', ParBB.step tge sp (Iexec ti) y (Iterm ti' cf)
             /\ state_lessdef i' ti'.
  Proof.
    unfold schedule_oracle; intros. repeat (destruct_match; try discriminate). simplify.
    exploit abstr_sequence_correct; eauto; simplify.
    exploit abstr_check_correct; eauto. apply state_lessdef_refl. simplify.
    exploit abstr_seq_reverse_correct; eauto. apply state_lessdef_refl. simplify.
    exploit seqbb_step_parbb_step; eauto; intros.
    econstructor; split; eauto.
    etransitivity; eauto.
    etransitivity; eauto.
  Qed.

  Lemma step_cf_correct :
    forall cf ts s s' t,
      GibleSeq.step_cf_instr ge s cf t s' ->
      match_states s ts ->
      exists ts', step_cf_instr tge ts cf t ts'
             /\ match_states s' ts'.
  Proof. Admitted.

  Lemma match_states_stepBB :
    forall s f sp pc rs pr m sf' f' trs tps tm rs' pr' m' trs' tpr' tm',
      match_states (GibleSeq.State s f sp pc rs pr m) (State sf' f' sp pc trs tps tm) ->
      state_lessdef (mk_instr_state rs' pr' m') (mk_instr_state trs' tpr' tm') ->
      match_states (GibleSeq.State s f sp pc rs' pr' m') (State sf' f' sp pc trs' tpr' tm').
  Proof.
    inversion 1; subst; simplify.
    inv H0. econstructor; eauto.
  Qed.

  Theorem transl_step_correct :
    forall (S1 : GibleSeq.state) t S2,
      GibleSeq.step ge S1 t S2 ->
      forall (R1 : GiblePar.state),
        match_states S1 R1 ->
        exists R2, Smallstep.plus GiblePar.step tge R1 t R2 /\ match_states S2 R2.
  Proof.
    induction 1; repeat semantics_simpl.
    {
      exploit schedule_oracle_correct; eauto. constructor; eauto. simplify.
      destruct x0.
      pose proof H2 as X. eapply match_states_stepBB in X; eauto.
      exploit step_cf_correct; eauto. simplify.
      eexists; split. apply Smallstep.plus_one.
      econstructor; eauto. auto.
    }
    { unfold bind in *. inv TRANSL0. clear Learn. inv H0. destruct_match; crush.
      inv H2. unfold transl_function in Heqr. destruct_match; crush.
      inv Heqr.
      repeat econstructor; eauto.
      unfold bind in *. destruct_match; crush. }
    { inv TRANSL0.
      repeat econstructor;
        eauto using Events.E0_right. }
    { inv STACKS. inv H2. repeat econstructor; eauto.
      intros. apply PTree_matches; eauto. }
    Qed.

  Lemma transl_initial_states:
    forall S,
      GibleSeq.initial_state prog S ->
      exists R, GiblePar.initial_state tprog R /\ match_states S R.
  Proof.
    induction 1.
    exploit function_ptr_translated; eauto. intros [tf [A B]].
    econstructor; split.
    econstructor. apply (Genv.init_mem_transf_partial TRANSL); eauto.
    replace (prog_main tprog) with (prog_main prog). rewrite symbols_preserved; eauto.
    symmetry; eapply match_program_main; eauto.
    eexact A.
    rewrite <- H2. apply sig_transl_function; auto.
    constructor. auto. constructor.
  Qed.

  Lemma transl_final_states:
    forall S R r,
      match_states S R -> GibleSeq.final_state S r -> GiblePar.final_state R r.
  Proof.
    intros. inv H0. inv H. inv STACKS. constructor.
  Qed.

  Theorem transf_program_correct:
    Smallstep.forward_simulation (GibleSeq.semantics prog) (GiblePar.semantics tprog).
  Proof.
    eapply Smallstep.forward_simulation_plus.
    apply senv_preserved.
    eexact transl_initial_states.
    eexact transl_final_states.
    exact transl_step_correct.
  Qed.

End CORRECTNESS.
