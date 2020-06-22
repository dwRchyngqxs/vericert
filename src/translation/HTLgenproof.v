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

From compcert Require RTL Registers AST Integers.
From compcert Require Import Globalenvs Memory.
From coqup Require Import Coquplib HTLgenspec HTLgen Value AssocMap Array.
From coqup Require HTL Verilog.

Require Import Lia.

Local Open Scope assocmap.

Hint Resolve Smallstep.forward_simulation_plus : htlproof.
Hint Resolve AssocMap.gss : htlproof.
Hint Resolve AssocMap.gso : htlproof.

Hint Unfold find_assocmap AssocMapExt.get_default : htlproof.

Inductive match_assocmaps : RTL.function -> RTL.regset -> assocmap -> Prop :=
  match_assocmap : forall f rs am,
    (forall r, Ple r (RTL.max_reg_function f) ->
               val_value_lessdef (Registers.Regmap.get r rs) am#r) ->
    match_assocmaps f rs am.
Hint Constructors match_assocmaps : htlproof.

Definition state_st_wf (m : HTL.module) (s : HTL.state) :=
  forall st asa asr res,
  s = HTL.State res m st asa asr ->
  asa!(m.(HTL.mod_st)) = Some (posToValue 32 st).
Hint Unfold state_st_wf : htlproof.

Inductive match_arrs (m : HTL.module) (f : RTL.function) (sp : Values.val) (mem : mem) :
  Verilog.assocmap_arr -> Prop :=
| match_arr : forall asa stack,
    asa ! (m.(HTL.mod_stk)) = Some stack /\
    stack.(arr_length) = Z.to_nat (f.(RTL.fn_stacksize) / 4) /\
    (forall ptr,
        0 <= ptr < Z.of_nat m.(HTL.mod_stk_len) ->
        opt_val_value_lessdef (Mem.loadv AST.Mint32 mem
                                         (Values.Val.offset_ptr sp (Integers.Ptrofs.repr (4 * ptr))))
                              (Option.default (NToValue 32 0)
                                 (Option.join (array_get_error (Z.to_nat ptr) stack)))) ->
    match_arrs m f sp mem asa.

Inductive match_stacks (mem : mem) : list RTL.stackframe -> list HTL.stackframe -> Prop :=
| match_stacks_nil :
    match_stacks mem nil nil
| match_stacks_cons :
    forall cs lr r f sp pc rs m asr asa
           (TF : tr_module f m)
           (ST: match_stacks mem cs lr)
           (MA: match_assocmaps f rs asr)
           (MARR : match_arrs m f sp mem asa),
      match_stacks mem (RTL.Stackframe r f sp pc rs :: cs)
                       (HTL.Stackframe r m pc asr asa :: lr).

Definition stack_based (v : Values.val) (sp : Values.block) : Prop :=
   match v with
   | Values.Vptr sp' off => sp' = sp
   | _ => True
   end.

Definition reg_stack_based_pointers (sp : Values.block) (rs : Registers.Regmap.t Values.val) : Prop :=
  forall r, stack_based (Registers.Regmap.get r rs) sp.

Definition arr_stack_based_pointers (spb : Values.block) (m : mem) (stack_length : Z)
  (sp : Values.val) : Prop :=
  forall ptr,
    0 <= ptr < (stack_length / 4) ->
    stack_based (Option.default
                   Values.Vundef
                   (Mem.loadv AST.Mint32 m
                              (Values.Val.offset_ptr sp (Integers.Ptrofs.repr (4 * ptr)))))
                spb.

Inductive match_states : RTL.state -> HTL.state -> Prop :=
| match_state : forall asa asr sf f sp sp' rs mem m st res
    (MASSOC : match_assocmaps f rs asr)
    (TF : tr_module f m)
    (WF : state_st_wf m (HTL.State res m st asr asa))
    (MS : match_stacks mem sf res)
    (MARR : match_arrs m f sp mem asa)
    (SP : sp = Values.Vptr sp' (Integers.Ptrofs.repr 0))
    (RSBP: reg_stack_based_pointers sp' rs)
    (ASBP: arr_stack_based_pointers sp' mem (f.(RTL.fn_stacksize)) sp),
    match_states (RTL.State sf f sp st rs mem)
                 (HTL.State res m st asr asa)
| match_returnstate :
    forall
      v v' stack mem res
      (MS : match_stacks mem stack res),
      val_value_lessdef v v' ->
      match_states (RTL.Returnstate stack v mem) (HTL.Returnstate res v')
| match_initial_call :
    forall f m m0
    (TF : tr_module f m),
      match_states (RTL.Callstate nil (AST.Internal f) nil m0) (HTL.Callstate nil m nil).
Hint Constructors match_states : htlproof.

Definition match_prog (p: RTL.program) (tp: HTL.program) :=
  Linking.match_program (fun cu f tf => transl_fundef f = Errors.OK tf) eq p tp.

Lemma transf_program_match:
  forall p tp, HTLgen.transl_program p = Errors.OK tp -> match_prog p tp.
Proof.
  intros. apply Linking.match_transform_partial_program; auto.
Qed.

Lemma regs_lessdef_add_greater :
  forall f rs1 rs2 n v,
    Plt (RTL.max_reg_function f) n ->
    match_assocmaps f rs1 rs2 ->
    match_assocmaps f rs1 (AssocMap.set n v rs2).
Proof.
  inversion 2; subst.
  intros. constructor.
  intros. unfold find_assocmap. unfold AssocMapExt.get_default.
  rewrite AssocMap.gso. eauto.
  apply Pos.le_lt_trans with _ _ n in H2.
  unfold not. intros. subst. eapply Pos.lt_irrefl. eassumption. assumption.
Qed.
Hint Resolve regs_lessdef_add_greater : htlproof.

Lemma regs_lessdef_add_match :
  forall f rs am r v v',
    val_value_lessdef v v' ->
    match_assocmaps f rs am ->
    match_assocmaps f (Registers.Regmap.set r v rs) (AssocMap.set r v' am).
Proof.
  inversion 2; subst.
  constructor. intros.
  destruct (peq r0 r); subst.
  rewrite Registers.Regmap.gss.
  unfold find_assocmap. unfold AssocMapExt.get_default.
  rewrite AssocMap.gss. assumption.

  rewrite Registers.Regmap.gso; try assumption.
  unfold find_assocmap. unfold AssocMapExt.get_default.
  rewrite AssocMap.gso; eauto.
Qed.
Hint Resolve regs_lessdef_add_match : htlproof.

Lemma list_combine_none :
  forall n l,
    length l = n ->
    list_combine Verilog.merge_cell (list_repeat None n) l = l.
Proof.
  induction n; intros; simplify.
  - symmetry. apply length_zero_iff_nil. auto.
  - destruct l; simplify.
    rewrite list_repeat_cons.
    simplify. f_equal.
    eauto.
Qed.

Lemma combine_none :
  forall n a,
    a.(arr_length) = n ->
    arr_contents (combine Verilog.merge_cell (arr_repeat None n) a) = arr_contents a.
Proof.
  intros.
  unfold combine.
  simplify.

  rewrite <- (arr_wf a) in H.
  apply list_combine_none.
  assumption.
Qed.

(* Need to eventually move posToValue 32 to posToValueAuto, as that has this proof. *)
Lemma assumption_32bit :
  forall v,
    valueToPos (posToValue 32 v) = v.
Admitted.

Lemma st_greater_than_res :
  forall m res : positive,
    m <> res.
Admitted.

Lemma finish_not_return :
  forall r f : positive,
    r <> f.
Admitted.

Lemma finish_not_res :
  forall f r : positive,
    f <> r.
Admitted.

Lemma greater_than_max_func :
  forall f st,
    Plt (RTL.max_reg_function f) st.
Proof. Admitted.

Ltac inv_state :=
  match goal with
    MSTATE : match_states _ _ |- _ =>
    inversion MSTATE;
    match goal with
      TF : tr_module _ _ |- _ =>
      inversion TF;
      match goal with
        TC : forall _ _,
          Maps.PTree.get _ _ = Some _ -> tr_code _ _ _ _ _ _ _ _ _,
        H : Maps.PTree.get _ _ = Some _ |- _ =>
        apply TC in H; inversion H;
        match goal with
          TI : context[tr_instr] |- _ =>
          inversion TI
        end
      end
    end
end; subst.

Ltac unfold_func H :=
  match type of H with
  | ?f = _ => unfold f in H; repeat (unfold_match H)
  | ?f _ = _ => unfold f in H; repeat (unfold_match H)
  | ?f _ _ = _ => unfold f in H; repeat (unfold_match H)
  | ?f _ _ _ = _ => unfold f in H; repeat (unfold_match H)
  | ?f _ _ _ _ = _ => unfold f in H; repeat (unfold_match H)
  end.

Lemma init_reg_assoc_empty :
  forall f l,
    match_assocmaps f (RTL.init_regs nil l) (HTL.init_regs nil l).
Proof.
  induction l; simpl; constructor; intros.
  - rewrite Registers.Regmap.gi. unfold find_assocmap.
    unfold AssocMapExt.get_default. rewrite AssocMap.gempty.
    constructor.

  - rewrite Registers.Regmap.gi. unfold find_assocmap.
    unfold AssocMapExt.get_default. rewrite AssocMap.gempty.
    constructor.
Qed.

Section CORRECTNESS.

  Variable prog : RTL.program.
  Variable tprog : HTL.program.

  Hypothesis TRANSL : match_prog prog tprog.

(*  Let ge : RTL.genv := Globalenvs.Genv.globalenv prog.
  Let tge : HTL.genv := Globalenvs.Genv.globalenv tprog.

  Lemma symbols_preserved:
    forall (s: AST.ident), Genv.find_symbol tge s = Genv.find_symbol ge s.
  Proof
    (Genv.find_symbol_transf_partial TRANSL).

  Lemma function_ptr_translated:
    forall (b: Values.block) (f: RTL.fundef),
      Genv.find_funct_ptr ge b = Some f ->
      exists tf,
        Genv.find_funct_ptr tge b = Some tf /\ transl_fundef f = Errors.OK tf.
  Proof.
    intros. exploit (Genv.find_funct_ptr_match TRANSL); eauto.
    intros (cu & tf & P & Q & R); exists tf; auto.
  Qed.

  Lemma functions_translated:
    forall (v: Values.val) (f: RTL.fundef),
      Genv.find_funct ge v = Some f ->
      exists tf,
        Genv.find_funct tge v = Some tf /\ transl_fundef f = Errors.OK tf.
  Proof.
    intros. exploit (Genv.find_funct_match TRANSL); eauto.
    intros (cu & tf & P & Q & R); exists tf; auto.
  Qed.

  Lemma senv_preserved:
    Senv.equiv (Genv.to_senv ge) (Genv.to_senv tge).
  Proof
    (Genv.senv_transf_partial TRANSL).
  Hint Resolve senv_preserved : htlproof.

  Lemma eval_correct :
    forall sp op rs args m v v' e asr asa f,
      Op.eval_operation ge sp op
(List.map (fun r : BinNums.positive => Registers.Regmap.get r rs) args) m = Some v ->
      tr_op op args e ->
      val_value_lessdef v v' ->
      Verilog.expr_runp f asr asa e v'.
  Admitted.

  Lemma eval_cond_correct :
    forall cond (args : list Registers.reg) s1 c s' i rs args m b f asr asa,
    translate_condition cond args s1 = OK c s' i ->
    Op.eval_condition
      cond
      (List.map (fun r : BinNums.positive => Registers.Regmap.get r rs) args)
      m = Some b ->
    Verilog.expr_runp f asr asa c (boolToValue 32 b).
  Admitted.

  (** The proof of semantic preservation for the translation of instructions
      is a simulation argument based on diagrams of the following form:
<<
                      match_states
    code st rs ---------------- State m st assoc
         ||                             |
         ||                             |
         ||                             |
         \/                             v
    code st rs' --------------- State m st assoc'
                      match_states
>>
      where [tr_code c data control fin rtrn st] is assumed to hold.

      The precondition and postcondition is that that should hold is [match_assocmaps rs assoc].
   *)

  Definition transl_instr_prop (instr : RTL.instruction) : Prop :=
    forall m asr asa fin rtrn st stmt trans res,
      tr_instr fin rtrn st (m.(HTL.mod_stk)) instr stmt trans ->
      exists asr' asa',
        HTL.step tge (HTL.State res m st asr asa) Events.E0 (HTL.State res m st asr' asa').

  Theorem transl_step_correct:
    forall (S1 : RTL.state) t S2,
      RTL.step ge S1 t S2 ->
      forall (R1 : HTL.state),
        match_states S1 R1 ->
        exists R2, Smallstep.plus HTL.step tge R1 t R2 /\ match_states S2 R2.
  Proof.
    induction 1; intros R1 MSTATE; try inv_state.
    - (* Inop *)
      unfold match_prog in TRANSL.
      econstructor.
      split.
      apply Smallstep.plus_one.
      eapply HTL.step_module; eauto.
      (* processing of state *)
      econstructor.
      simplify.
      econstructor.
      econstructor.
      econstructor.
      simplify.

      unfold Verilog.merge_regs.
      unfold_merge. apply AssocMap.gss.

      (* prove match_state *)
      rewrite assumption_32bit.
      econstructor; simplify; eauto.

      unfold Verilog.merge_regs.
      unfold_merge. simpl. apply regs_lessdef_add_greater. apply greater_than_max_func.
      assumption.
      unfold Verilog.merge_regs.
      unfold state_st_wf. inversion 1. subst. unfold_merge. apply AssocMap.gss.

      (* prove match_arrs *)
      invert MARR. simplify.
      unfold HTL.empty_stack. simplify. unfold Verilog.merge_arrs.
      econstructor.
      simplify. repeat split.

      rewrite AssocMap.gcombine.
      2: { reflexivity. }
      rewrite AssocMap.gss.
      unfold Verilog.merge_arr.
      setoid_rewrite H1.
      reflexivity.

      rewrite combine_length.
      unfold arr_repeat. simplify.
      rewrite list_repeat_len.
      reflexivity.

      unfold arr_repeat. simplify.
      rewrite list_repeat_len; auto.
      intros.
      erewrite array_get_error_equal.
      eauto. apply combine_none.

      assumption.

    - (* Iop *)
      (* destruct v eqn:?; *)
      (*          try ( *)
      (*            destruct op eqn:?; inversion H21; simpl in H0; repeat (unfold_match H0); *)
      (*            inversion H0; subst; simpl in *; try (unfold_func H4); try (unfold_func H5); *)
      (*            try (unfold_func H6); *)
      (*            try (unfold Op.eval_addressing32 in H6; repeat (unfold_match H6); inversion H6; *)
      (*                 unfold_func H3); *)

      (*            inversion Heql; inversion MASSOC; subst; *)
      (*            assert (HPle : Ple r (RTL.max_reg_function f)) *)
      (*              by (eapply RTL.max_reg_function_use; eauto; simpl; auto); *)
      (*            apply H1 in HPle; inversion HPle; *)
      (*            rewrite H2 in *; discriminate *)
      (*          ). *)

      (* + econstructor. split. *)
      (* apply Smallstep.plus_one. *)
      (* eapply HTL.step_module; eauto. *)
      (* econstructor; simpl; trivial. *)
      (* constructor; trivial. *)
      (* econstructor; simpl; eauto. *)
      (* eapply eval_correct; eauto. constructor. *)
      (* unfold_merge. simpl. *)
      (* rewrite AssocMap.gso. *)
      (* apply AssocMap.gss. *)
      (* apply st_greater_than_res. *)

      (* (* match_states *) *)
      (* assert (pc' = valueToPos (posToValue 32 pc')). auto using assumption_32bit. *)
      (* rewrite <- H1. *)
      (* constructor; auto. *)
      (* unfold_merge. *)
      (* apply regs_lessdef_add_match. *)
      (* constructor. *)
      (* apply regs_lessdef_add_greater. *)
      (* apply greater_than_max_func. *)
      (* assumption. *)

      (* unfold state_st_wf. intros. inversion H2. subst. *)
      (* unfold_merge. *)
      (* rewrite AssocMap.gso. *)
      (* apply AssocMap.gss. *)
      (* apply st_greater_than_res. *)

      (* + econstructor. split. *)
      (* apply Smallstep.plus_one. *)
      (* eapply HTL.step_module; eauto. *)
      (* econstructor; simpl; trivial. *)
      (* constructor; trivial. *)
      (* econstructor; simpl; eauto. *)
      (* eapply eval_correct; eauto. *)
      (* constructor. rewrite valueToInt_intToValue. trivial. *)
      (* unfold_merge. simpl. *)
      (* rewrite AssocMap.gso. *)
      (* apply AssocMap.gss. *)
      (* apply st_greater_than_res. *)

      (* (* match_states *) *)
      (* assert (pc' = valueToPos (posToValue 32 pc')). auto using assumption_32bit. *)
      (* rewrite <- H1. *)
      (* constructor. *)
      (* unfold_merge. *)
      (* apply regs_lessdef_add_match. *)
      (* constructor. *)
      (* symmetry. apply valueToInt_intToValue. *)
      (* apply regs_lessdef_add_greater. *)
      (* apply greater_than_max_func. *)
      (* assumption. assumption. *)

      (* unfold state_st_wf. intros. inversion H2. subst. *)
      (* unfold_merge. *)
      (* rewrite AssocMap.gso. *)
      (* apply AssocMap.gss. *)
      (* apply st_greater_than_res. *)
      (* assumption. *)
      admit.

      Ltac rt :=
        repeat match goal with
        | [ _ : error _ _ = OK _ _ _ |- _ ] => discriminate
        | [ _ : context[if (?x && ?y) then _ else _] |- _ ] =>
          let EQ1 := fresh "EQ" in
          let EQ2 := fresh "EQ" in
          destruct x eqn:EQ1; destruct y eqn:EQ2; simpl in *
        | [ _ : context[if ?x then _ else _] |- _ ] =>
          let EQ := fresh "EQ" in
          destruct x eqn:EQ; simpl in *
        | [ H : ret _ _ = _  |- _ ] => invert H
        | [ _ : context[match ?x with | _ => _ end] |- _ ] => destruct x
        end.

      Opaque Z.mul.

    - (* FIXME: Should be able to use the spec to avoid destructing here. *)
      destruct c, chunk, addr, args; simplify; rt; simplify.

      + admit. (* FIXME: Alignment *)

      + (* FIXME: Why is this degenerate? Should we support this mode? *)
        unfold Op.eval_addressing in H0.
        destruct (Archi.ptr64) eqn:ARCHI; simplify.
        destruct (Registers.Regmap.get r0 rs) eqn:EQr0; discriminate.

      + invert MARR. simplify.

        unfold Op.eval_addressing in H0.
        destruct (Archi.ptr64) eqn:ARCHI; simplify.

        unfold reg_stack_based_pointers in RSBP.
        pose proof (RSBP r0) as RSBPr0.
        pose proof (RSBP r1) as RSBPr1.

        destruct (Registers.Regmap.get r0 rs) eqn:EQr0;
        destruct (Registers.Regmap.get r1 rs) eqn:EQr1; simplify.

        rewrite ARCHI in H1. simplify.
        subst.

        eexists. split.
        eapply Smallstep.plus_one.
        eapply HTL.step_module; eauto.
        econstructor. econstructor. econstructor. simplify.
        econstructor. econstructor. econstructor. simplify.
        eapply Verilog.erun_Vbinop with (EQ := ?[EQ1]). (* FIXME: These will be shelved and cause sadness. *)
        eapply Verilog.erun_Vbinop with (EQ := ?[EQ2]).
        eapply Verilog.erun_Vbinop with (EQ := ?[EQ3]).
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        eapply Verilog.erun_Vbinop with (EQ := ?[EQ4]).
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor.
        econstructor. (* FIXME: Oh dear. *)

        unfold Verilog.arr_assocmap_lookup. simplify. setoid_rewrite H3.
        f_equal.

        simplify. unfold Verilog.merge_regs.
        unfold_merge.
        rewrite AssocMap.gso.
        apply AssocMap.gss.
        apply st_greater_than_res.

        simplify. rewrite assumption_32bit.
        econstructor; simplify; eauto.

        unfold Verilog.merge_regs. unfold_merge.
        apply regs_lessdef_add_match.

        pose proof H1.
        assert (Integers.Ptrofs.repr 0 = Integers.Ptrofs.zero) by reflexivity.
        rewrite H4 in H5.
        setoid_rewrite Integers.Ptrofs.add_zero_l in H5.

        specialize (H5 (uvalueToZ
                (vplus (vplus (vdivs asr # r0 (ZToValue 32 4) ?EQ3) (ZToValue 32 (z0 / 4)) ?EQ2)
                   (vmul asr # r1 (ZToValue 32 (z / 4)) ?EQ4) ?EQ1))).

        assert (0 <= uvalueToZ
                      (vplus (vplus (vdivs asr # r0 (ZToValue 32 4) ?EQ3) (ZToValue 32 (z0 / 4)) ?EQ2)
                             (vmul asr # r1 (ZToValue 32 (z / 4)) ?EQ4) ?EQ1) <
                Z.of_nat (Z.to_nat (RTL.fn_stacksize f / 4))) by admit.
        apply H5 in H6.

        invert MASSOC.
        pose proof (H7 r0).
        pose proof (H7 r1).
        assert (HPler0 : Ple r0 (RTL.max_reg_function f))
          by (eapply RTL.max_reg_function_use; eauto; simplify; eauto).
        assert (HPler1 : Ple r1 (RTL.max_reg_function f))
          by (eapply RTL.max_reg_function_use; eauto; simpl; auto).
        apply H8 in HPler0.
        apply H10 in HPler1.
        invert HPler0; invert HPler1; try congruence.
        rewrite EQr0 in H12.
        rewrite EQr1 in H13.

        assert ((Integers.Ptrofs.unsigned
            (Integers.Ptrofs.add i0
               (Integers.Ptrofs.of_int
                  (Integers.Int.add (Integers.Int.mul i1 (Integers.Int.repr z))
                                    (Integers.Int.repr z0))))) =
                (Integers.Ptrofs.unsigned
               (Integers.Ptrofs.repr
                  (4 *
                   uvalueToZ
                     (vplus
                        (vplus (vdivs asr # r0 (ZToValue 32 4) ?EQ3)
                           (ZToValue 32 (z0 / 4)) ?EQ2)
                        (vmul asr # r1 (ZToValue 32 (z / 4)) ?EQ4)
                        ?EQ1))))) by admit.

        rewrite <- H19 in H6.
        rewrite H0 in H6.
        invert H6.
        assert (forall x, Z.to_nat (uvalueToZ x) = valueToNat x) as VALUE_IDENTITY by admit.
        rewrite VALUE_IDENTITY in H21.
        assumption.

        apply regs_lessdef_add_greater.
        apply greater_than_max_func.
        assumption.

        unfold state_st_wf. inversion 1. simplify.
        unfold Verilog.merge_regs.
        unfold_merge. rewrite AssocMap.gso.
        apply AssocMap.gss.
        apply st_greater_than_res.

        econstructor.
        repeat split; simplify.
        unfold HTL.empty_stack.
        simplify.
        unfold Verilog.merge_arrs.

        rewrite AssocMap.gcombine.
        2: { reflexivity. }
        rewrite AssocMap.gss.
        unfold Verilog.merge_arr.
        setoid_rewrite H3.
        reflexivity.

        rewrite combine_length.
        unfold arr_repeat. simplify.
        rewrite list_repeat_len.
        reflexivity.

        unfold arr_repeat. simplify.
        rewrite list_repeat_len.
        congruence.

        intros.
        erewrite array_get_error_equal.
        eauto. apply combine_none.
        assumption.

        unfold reg_stack_based_pointers. intros.
        destruct (Pos.eq_dec r2 dst); subst.

        rewrite Registers.Regmap.gss.

        unfold arr_stack_based_pointers in ASBP.
        specialize (ASBP ((Integers.Ptrofs.unsigned
            (Integers.Ptrofs.add i0
               (Integers.Ptrofs.of_int
                  (Integers.Int.add (Integers.Int.mul i1 (Integers.Int.repr z))
                     (Integers.Int.repr z0))))) / 4)).
        exploit ASBP; auto; intros.
        1: {
          split.
          - admit. (*apply Z.div_pos; lia.*)
          - admit. (* apply Zmult_lt_reg_r with (p := 4); try lia. *)
            (* repeat rewrite ZLib.div_mul_undo; lia. *)
        }
        replace (4 * ((Integers.Ptrofs.unsigned
            (Integers.Ptrofs.add i0
               (Integers.Ptrofs.of_int
                  (Integers.Int.add (Integers.Int.mul i1 (Integers.Int.repr z))
                     (Integers.Int.repr z0)))))  / 4)) with (Integers.Ptrofs.unsigned
            (Integers.Ptrofs.add i0
               (Integers.Ptrofs.of_int
                  (Integers.Int.add (Integers.Int.mul i1 (Integers.Int.repr z))
                     (Integers.Int.repr z0)))))  in H0.
        2: {
          rewrite Z.mul_comm.
          admit.
          (* rewrite ZLib.div_mul_undo; lia. *)
        }
        rewrite Integers.Ptrofs.repr_unsigned in H0.
        simplify.
        assert (Integers.Ptrofs.repr 0 = Integers.Ptrofs.zero) by reflexivity.
        rewrite H4 in H0.
        setoid_rewrite Integers.Ptrofs.add_zero_l in H0.
        rewrite H1 in H0.
        simplify.
        assumption.

        rewrite Registers.Regmap.gso; auto.

      + invert MARR. simplify.

        unfold Op.eval_addressing in H0.
        destruct (Archi.ptr64) eqn:ARCHI; simplify.
        rewrite ARCHI in H0. simplify.

        (** Here we are assuming that any stack read will be within the bounds
            of the activation record. *)
        assert (0 <= Integers.Ptrofs.unsigned i0) as READ_BOUND_LOW by admit.
        assert (Integers.Ptrofs.unsigned i0 < f.(RTL.fn_stacksize)) as READ_BOUND_HIGH by admit.

        eexists. split.
        eapply Smallstep.plus_one.
        eapply HTL.step_module; eauto.
        econstructor. econstructor. econstructor. simplify.
        econstructor. econstructor. econstructor. econstructor. simplify.

        unfold Verilog.arr_assocmap_lookup. setoid_rewrite H3.
        f_equal.

        simplify. unfold Verilog.merge_regs.
        unfold_merge.
        rewrite AssocMap.gso.
        apply AssocMap.gss.
        apply st_greater_than_res.

        simplify. rewrite assumption_32bit.
        econstructor; simplify; eauto.

        unfold Verilog.merge_regs. unfold_merge.
        apply regs_lessdef_add_match.

        (** Equality proof *)
        (* FIXME: 32-bit issue. *)
        assert (forall x, valueToNat (ZToValue 32 x) = Z.to_nat x) as VALUE_IDENTITY by admit.
        rewrite VALUE_IDENTITY.
        specialize (H5 (Integers.Ptrofs.unsigned i0 / 4)).
        rewrite Z2Nat.id in H5; try lia.
        exploit H5; auto; intros.
        1: {
          split.
          - apply Z.div_pos; lia.
          - apply Zmult_lt_reg_r with (p := 4); try lia.
            repeat rewrite ZLib.div_mul_undo; lia.
        }
        2: {
          assert (0 < RTL.fn_stacksize f) by lia.
          apply Z.div_pos; lia.
        }
        replace (4 * (Integers.Ptrofs.unsigned i0 / 4)) with (Integers.Ptrofs.unsigned i0) in H0.
        2: {
          rewrite Z.mul_comm.
          rewrite ZLib.div_mul_undo; lia.
        }
        rewrite Integers.Ptrofs.repr_unsigned in H0.
        rewrite H1 in H0.
        invert H0. assumption.

        apply regs_lessdef_add_greater.
        apply greater_than_max_func.
        assumption.

        unfold state_st_wf. inversion 1. simplify.
        unfold Verilog.merge_regs.
        unfold_merge. rewrite AssocMap.gso.
        apply AssocMap.gss.
        apply st_greater_than_res.

        econstructor.
        repeat split; simplify.
        unfold HTL.empty_stack.
        simplify.
        unfold Verilog.merge_arrs.

        rewrite AssocMap.gcombine.
        2: { reflexivity. }
        rewrite AssocMap.gss.
        unfold Verilog.merge_arr.
        setoid_rewrite H3.
        reflexivity.

        rewrite combine_length.
        unfold arr_repeat. simplify.
        rewrite list_repeat_len.
        reflexivity.

        unfold arr_repeat. simplify.
        rewrite list_repeat_len.
        congruence.

        intros.
        erewrite array_get_error_equal.
        eauto. apply combine_none.
        assumption.

        unfold reg_stack_based_pointers. intros.
        destruct (Pos.eq_dec r0 dst); subst.

        rewrite Registers.Regmap.gss.

        unfold arr_stack_based_pointers in ASBP.
        specialize (ASBP (Integers.Ptrofs.unsigned i0 / 4)).
        exploit ASBP; auto; intros.
        1: {
          split.
          - apply Z.div_pos; lia.
          - apply Zmult_lt_reg_r with (p := 4); try lia.
            repeat rewrite ZLib.div_mul_undo; lia.
        }
        replace (4 * (Integers.Ptrofs.unsigned i0 / 4)) with (Integers.Ptrofs.unsigned i0) in H0.
        2: {
          rewrite Z.mul_comm.
          rewrite ZLib.div_mul_undo; lia.
        }
        rewrite Integers.Ptrofs.repr_unsigned in H0.
        simplify.
        rewrite H1 in H0.
        simplify.
        assumption.

        rewrite Registers.Regmap.gso; auto.

    - destruct c, chunk, addr, args; simplify; rt; simplify.
      + admit.
      + admit.
      + admit.

      (* + eexists. split. *)
      (*   eapply Smallstep.plus_one. *)
      (*   eapply HTL.step_module; eauto. *)
      (*   econstructor. econstructor. econstructor. simplify. *)
      + admit.

    - eexists. split. apply Smallstep.plus_one.
      eapply HTL.step_module; eauto.
      eapply Verilog.stmnt_runp_Vnonblock_reg with
          (rhsval := if b then posToValue 32 ifso else posToValue 32 ifnot).

      constructor.

      simpl.
      destruct b.
      eapply Verilog.erun_Vternary_true.
      eapply eval_cond_correct; eauto.
      constructor.
      apply boolToValue_ValueToBool.
      eapply Verilog.erun_Vternary_false.
      eapply eval_cond_correct; eauto.
      constructor.
      apply boolToValue_ValueToBool.
      constructor.
      unfold_merge.
      apply AssocMap.gss.

      destruct b.
      rewrite assumption_32bit.
      apply match_state.
      unfold_merge.
      apply regs_lessdef_add_greater. apply greater_than_max_func.
      assumption. assumption.

      unfold state_st_wf. intros. inversion H1.
      subst. unfold_merge.
      apply AssocMap.gss.
      assumption.

      assumption.

      rewrite assumption_32bit.
      apply match_state.
      unfold_merge.
      apply regs_lessdef_add_greater. apply greater_than_max_func. assumption.
      assumption.

      unfold state_st_wf. intros. inversion H1.
      subst. unfold_merge.
      apply AssocMap.gss.
      assumption.

      assumption.

    - (* Return *)
      econstructor. split.
      eapply Smallstep.plus_two.
      
      eapply HTL.step_module; eauto.
      constructor.
      econstructor; simpl; trivial.
      econstructor; simpl; trivial.
      constructor.
      econstructor; simpl; trivial.
      constructor.

      constructor. constructor.

      unfold_merge. simpl.
      rewrite AssocMap.gso.
      rewrite AssocMap.gso.
      unfold state_st_wf in WF. eapply WF. reflexivity.
      apply st_greater_than_res. apply st_greater_than_res.

      apply HTL.step_finish.
      unfold_merge; simpl.
      rewrite AssocMap.gso.
      apply AssocMap.gss.
      apply finish_not_return.
      apply AssocMap.gss.
      rewrite Events.E0_left. reflexivity.
      constructor.

      admit.
      constructor.

    - econstructor. split.
      eapply Smallstep.plus_two.
      eapply HTL.step_module; eauto.
      constructor.
      econstructor; simpl; trivial.
      econstructor; simpl; trivial.

      constructor. constructor.

      constructor.
      econstructor; simpl; trivial.
      apply Verilog.erun_Vvar. trivial.
      unfold_merge. simpl.
      rewrite AssocMap.gso.
      rewrite AssocMap.gso.
      unfold state_st_wf in WF. eapply WF. trivial.
      apply st_greater_than_res. apply st_greater_than_res. trivial.

      apply HTL.step_finish.
      unfold_merge.
      rewrite AssocMap.gso.
      apply AssocMap.gss.
      apply finish_not_return.
      apply AssocMap.gss.
      rewrite Events.E0_left. trivial.

      constructor.
      admit.

      simpl. inversion MASSOC. subst.
      unfold find_assocmap, AssocMapExt.get_default. rewrite AssocMap.gso.
      apply H1. eapply RTL.max_reg_function_use. eauto. simpl; tauto.
      apply st_greater_than_res.

    - inversion MSTATE; subst. inversion TF; subst.
      econstructor. split. apply Smallstep.plus_one.
      eapply HTL.step_call. simpl.

      constructor. apply regs_lessdef_add_greater.
      apply greater_than_max_func.
      apply init_reg_assoc_empty. assumption. unfold state_st_wf.
      intros. inv H1. apply AssocMap.gss. constructor.

      econstructor; simpl.
      reflexivity.
      rewrite AssocMap.gss. reflexivity.
      intros.
      destruct (Mem.load AST.Mint32 m' stk
                         (Integers.Ptrofs.unsigned (Integers.Ptrofs.add
                                                      Integers.Ptrofs.zero
                                                      (Integers.Ptrofs.repr ptr)))) eqn:LOAD.
      pose proof Mem.load_alloc_same as LOAD_ALLOC.
      pose proof H as ALLOC.
      eapply LOAD_ALLOC in ALLOC.
      2: { exact LOAD. }
      rewrite ALLOC.
      repeat constructor.
      constructor.

    - inversion MSTATE; subst. inversion MS; subst. econstructor.
      split. apply Smallstep.plus_one.
      constructor.

      constructor; auto. constructor; auto. apply regs_lessdef_add_match; auto.
      apply regs_lessdef_add_greater. apply greater_than_max_func. auto.

      unfold state_st_wf. intros. inv H. rewrite AssocMap.gso.
      rewrite AssocMap.gss. trivial. apply st_greater_than_res.

      Unshelve.
      exact (AssocMap.empty value).
      exact (AssocMap.empty value).
      exact (AssocMap.empty value).
      exact (AssocMap.empty value).
      (* exact (ZToValue 32 0). *)
      (* exact (AssocMap.empty value). *)
      (* exact (AssocMap.empty value). *)
      (* exact (AssocMap.empty value). *)
      (* exact (AssocMap.empty value). *)
  Admitted.
  Hint Resolve transl_step_correct : htlproof.

  (* Had to admit proof because currently there is no way to force main to be Internal. *)
  Lemma transl_initial_states :
    forall s1 : Smallstep.state (RTL.semantics prog),
      Smallstep.initial_state (RTL.semantics prog) s1 ->
      exists s2 : Smallstep.state (HTL.semantics tprog),
        Smallstep.initial_state (HTL.semantics tprog) s2 /\ match_states s1 s2.
  Proof.
    induction 1.
    exploit function_ptr_translated; eauto.
    intros [tf [A B]].
    unfold transl_fundef, Errors.bind in B.
    repeat (unfold_match B). inversion B. subst.
    econstructor; split. econstructor.
    apply (Genv.init_mem_transf_partial TRANSL); eauto.
    replace (AST.prog_main tprog) with (AST.prog_main prog).
    rewrite symbols_preserved; eauto.
    symmetry; eapply Linking.match_program_main; eauto.
    Admitted.
    (*eexact A. trivial.
    constructor.
    apply transl_module_correct. auto.
  Qed.*)
  Hint Resolve transl_initial_states : htlproof.

  Lemma transl_final_states :
    forall (s1 : Smallstep.state (RTL.semantics prog))
           (s2 : Smallstep.state (HTL.semantics tprog))
           (r : Integers.Int.int),
      match_states s1 s2 ->
      Smallstep.final_state (RTL.semantics prog) s1 r ->
      Smallstep.final_state (HTL.semantics tprog) s2 r.
  Proof.
    intros. inv H0. inv H. inv H4. inv MS. constructor. trivial.
  Qed.
  Hint Resolve transl_final_states : htlproof.*)

Theorem transf_program_correct:
  Smallstep.forward_simulation (RTL.semantics prog) (HTL.semantics tprog).
Proof.
(*  eapply Smallstep.forward_simulation_plus.
  apply senv_preserved.
  eexact transl_initial_states.
  eexact transl_final_states.
  exact transl_step_correct.*)
Admitted.

End CORRECTNESS.
