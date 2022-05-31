(*|
..
   Vericert: Verified high-level synthesis.
   Copyright (C) 2022 Yann Herklotz <yann@yannherklotz.com>

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.

================
RTLBlockgenproof
================

.. coq:: none
|*)

Require Import compcert.common.AST.
Require Import compcert.common.Errors.
Require Import compcert.common.Globalenvs.
Require Import compcert.lib.Maps.
Require Import compcert.backend.Registers.
Require Import compcert.common.Smallstep.
Require Import compcert.common.Events.
Require Import compcert.common.Memory.
Require Import compcert.common.Values.

Require Import vericert.common.Vericertlib.
Require Import vericert.common.DecEq.
Require Import vericert.hls.Gible.
Require Import vericert.hls.GibleSeq.
Require Import vericert.hls.CondElim.

#[local] Open Scope positive.

Lemma cf_in_step :
  forall A B ge sp is_ is_' bb cf,
    @SeqBB.step A B ge sp (Iexec is_) bb (Iterm is_' cf) ->
    exists p, In (RBexit p cf) bb
              /\ Option.default true (Option.map (eval_predf (is_ps is_')) p) = true.
  Proof. Admitted.

Lemma forbidden_term_trans :
  forall A B ge sp i c b i' c',
    ~ @SeqBB.step A B ge sp (Iterm i c) b (Iterm i' c').
Proof. induction b; unfold not; intros; inv H. Qed.

Lemma random1 :
  forall A B ge sp is_ b is_' cf,
    @SeqBB.step A B ge sp (Iexec is_) b (Iterm is_' cf) ->
    exists p b', SeqBB.step ge sp (Iexec is_) (b' ++ (RBexit p cf) :: nil) (Iterm is_' cf)
                 /\ Forall2 eq (b' ++ (RBexit p cf) :: nil) b.
Proof.
Admitted.

Lemma replace_section_spec :
  forall A B ge sp is_ is_' bb cf,
    @SeqBB.step A B ge sp (Iexec is_) bb (Iterm is_' cf) ->
    exists p,
      @SeqBB.step A B ge sp (Iexec is_)
                  (snd (replace_section elim_cond_s p bb))
                  (Iterm is_' cf). Admitted.

Lemma transf_block_spec :
  forall f pc b,
    f.(fn_code) ! pc = Some b ->
    exists p,
      (transf_function f).(fn_code) ! pc
      = Some (snd (replace_section elim_cond_s p b)). Admitted.

Variant match_stackframe : stackframe -> stackframe -> Prop :=
  | match_stackframe_init :
    forall res f tf sp pc rs p p'
           (TF: transf_function f = tf),
      match_stackframe (Stackframe res f sp pc rs p) (Stackframe res tf sp pc rs p').

Variant match_states : state -> state -> Prop :=
  | match_state :
    forall stk stk' f tf sp pc rs p p0 m
           (TF: transf_function f = tf)
           (STK: Forall2 match_stackframe stk stk'),
      match_states (State stk f sp pc rs p m) (State stk' tf sp pc rs p0 m)
  | match_callstate :
    forall cs cs' f tf args m
           (TF: transf_fundef f = tf)
           (STK: Forall2 match_stackframe cs cs'),
      match_states (Callstate cs f args m) (Callstate cs' tf args m)
  | match_returnstate :
    forall cs cs' v m
           (STK: Forall2 match_stackframe cs cs'),
      match_states (Returnstate cs v m) (Returnstate cs' v m)
.

Definition match_prog (p: program) (tp: program) :=
  Linking.match_program (fun cu f tf => tf = transf_fundef f) eq p tp.

Section CORRECTNESS.

  Context (prog tprog : program).

  Let ge : genv := Globalenvs.Genv.globalenv prog.
  Let tge : genv := Globalenvs.Genv.globalenv tprog.

  Context (TRANSL : match_prog prog tprog).

  Lemma symbols_preserved:
    forall (s: AST.ident), Genv.find_symbol tge s = Genv.find_symbol ge s.
  Proof using TRANSL. intros. eapply (Genv.find_symbol_match TRANSL). Qed.

  Lemma senv_preserved:
    Senv.equiv (Genv.to_senv ge) (Genv.to_senv tge).
  Proof using TRANSL. intros; eapply (Genv.senv_transf TRANSL). Qed.

  Lemma function_ptr_translated:
    forall b f,
      Genv.find_funct_ptr ge b = Some f ->
      Genv.find_funct_ptr tge b = Some (transf_fundef f).
  Proof (Genv.find_funct_ptr_transf TRANSL).

  Lemma sig_transf_function:
    forall (f tf: fundef),
      funsig (transf_fundef f) = funsig f.
  Proof using.
    unfold transf_fundef. unfold AST.transf_fundef; intros. destruct f.
    unfold transf_function. auto. auto.
  Qed.

  Lemma transf_initial_states :
    forall s1,
      initial_state prog s1 ->
      exists s2, initial_state tprog s2 /\ match_states s1 s2.
  Proof using TRANSL.
    induction 1.
    exploit function_ptr_translated; eauto; intros.
    do 2 econstructor; simplify. econstructor.
    apply (Genv.init_mem_transf TRANSL); eauto.
    replace (prog_main tprog) with (prog_main prog). rewrite symbols_preserved; eauto.
    symmetry; eapply Linking.match_program_main; eauto. eauto.
    erewrite sig_transf_function; eauto. constructor. auto. auto.
  Qed.

  Lemma transf_final_states :
    forall s1 s2 r,
      match_states s1 s2 -> final_state s1 r -> final_state s2 r.
  Proof using.
    inversion 2; crush. subst. inv H. inv STK. econstructor.
  Qed.

  Lemma transf_step_correct:
    forall (s1 : state) (t : trace) (s1' : state),
      step ge s1 t s1' ->
      forall s2 : state,
        match_states s1 s2 ->
        exists s2' : state, step tge s2 t s2' /\ match_states s1' s2'.
  Proof.
    induction 1; intros.
    + inv H2. eapply cf_in_step in H0; simplify.
      do 2 econstructor. econstructor; eauto. admit. Admitted.

  Theorem transf_program_correct:
    forward_simulation (semantics prog) (semantics tprog).
  Proof using TRANSL.
    eapply forward_simulation_step.
    + apply senv_preserved.
    + apply transf_initial_states.
    + apply transf_final_states.
    + apply transf_step_correct.
  Qed.


End CORRECTNESS.
