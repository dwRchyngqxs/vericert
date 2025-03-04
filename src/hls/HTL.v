(*
 * Vericert: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
 *               2020 James Pollard <j@mes.dev>
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

Require Import Coq.FSets.FMapPositive.
Require Import Coq.micromega.Lia.

Require compcert.common.Events.
Require compcert.common.Globalenvs.
Require compcert.common.Smallstep.
Require compcert.common.Values.
Require Import compcert.lib.Integers.
Require Import compcert.lib.Maps.

Require Import vericert.common.Vericertlib.
Require Import vericert.hls.Array.
Require Import vericert.hls.FunctionalUnits.
Require vericert.hls.Verilog.
Require Import AssocMap.
Require Import ValueInt.

Local Open Scope positive.

(*|
The purpose of the hardware transfer language (HTL) is to create a more
hardware-like layout that is still similar to the register transfer language
(RTL) that it came from. The main change is that function calls become module
instantiations and that we now describe a state machine instead of a
control-flow graph.
|*)

Local Open Scope assocmap.

Definition reg := positive.
Definition node := positive.

Definition datapath := PTree.t Verilog.stmnt.
Definition controllogic := PTree.t Verilog.stmnt.

Definition map_well_formed {A : Type} (m : PTree.t A) : Prop :=
  forall p0 : positive,
    In p0 (map fst (Maps.PTree.elements m)) ->
    (Z.pos p0 <= Integers.Int.max_unsigned)%Z.

Record module: Type :=
  mkmodule {
    mod_params : list reg;
    mod_datapath : datapath;
    mod_controllogic : controllogic;
    mod_entrypoint : node;
    mod_st : reg;
    mod_finish : reg;
    mod_return : reg;
    mod_start : reg;
    mod_reset : reg;
    mod_clk : reg;
    mod_scldecls : AssocMap.t (option Verilog.io * Verilog.scl_decl);
    mod_arrdecls : AssocMap.t (option Verilog.io * Verilog.arr_decl);
    mod_ram : ram;
  }.

Definition fundef := AST.fundef module.

Definition program := AST.program fundef unit.

Fixpoint init_regs (vl : list value) (rl : list reg) {struct rl} :=
  match rl, vl with
  | r :: rl', v :: vl' => AssocMap.set r v (init_regs vl' rl')
  | _, _ => empty_assocmap
  end.

Definition empty_stack (m : module) : Verilog.assocmap_arr :=
  (AssocMap.set m.(mod_ram).(ram_mem) (Array.arr_repeat None m.(mod_ram).(ram_size)) (AssocMap.empty Verilog.arr)).

(*|
Operational Semantics
=====================
|*)

Definition genv := Globalenvs.Genv.t fundef unit.

Inductive stackframe : Type :=
  Stackframe :
    forall  (res : reg)
            (m : module)
            (pc : node)
            (reg_assoc : Verilog.assocmap_reg)
            (arr_assoc : Verilog.assocmap_arr),
      stackframe.

Inductive state : Type :=
| State :
    forall (stack : list stackframe)
           (m : module)
           (st : node)
           (reg_assoc : Verilog.assocmap_reg)
           (arr_assoc : Verilog.assocmap_arr), state
| Returnstate :
    forall (res : list stackframe)
           (v : value), state
| Callstate :
    forall (stack : list stackframe)
           (m : module)
           (args : list value), state.

Inductive exec_ram:
  Verilog.reg_associations -> Verilog.arr_associations -> ram ->
  Verilog.reg_associations -> Verilog.arr_associations -> Prop :=
| exec_ram_Some_idle:
    forall ra ar r,
      Int.eq (Verilog.assoc_blocking ra)#(ram_en r, 32)
             (Verilog.assoc_blocking ra)#(ram_u_en r, 32) = true ->
      exec_ram ra ar r ra ar
| exec_ram_Some_write:
    forall ra ar r d_in addr en wr_en u_en,
      Int.eq en u_en = false ->
      Int.eq wr_en (ZToValue 0) = false ->
      (Verilog.assoc_blocking ra)#(ram_en r, 32) = en ->
      (Verilog.assoc_blocking ra)!(ram_u_en r) = Some u_en ->
      (Verilog.assoc_blocking ra)!(ram_wr_en r) = Some wr_en ->
      (Verilog.assoc_blocking ra)!(ram_d_in r) = Some d_in ->
      (Verilog.assoc_blocking ra)!(ram_addr r) = Some addr ->
      exec_ram ra ar r (Verilog.nonblock_reg (ram_en r) ra u_en)
               (Verilog.nonblock_arr (ram_mem r) (valueToNat addr) ar d_in)
| exec_ram_Some_read:
    forall ra ar r addr v_d_out en u_en,
      Int.eq en u_en = false ->
      (Verilog.assoc_blocking ra)#(ram_en r, 32) = en ->
      (Verilog.assoc_blocking ra)!(ram_u_en r) = Some u_en ->
      (Verilog.assoc_blocking ra)!(ram_wr_en r) = Some (ZToValue 0) ->
      (Verilog.assoc_blocking ra)!(ram_addr r) = Some addr ->
      Verilog.arr_assocmap_lookup (Verilog.assoc_blocking ar)
                                  (ram_mem r) (valueToNat addr) = Some v_d_out ->
      exec_ram ra ar r (Verilog.nonblock_reg (ram_en r)
                               (Verilog.nonblock_reg (ram_d_out r) ra v_d_out) u_en) ar.

Inductive step : genv -> state -> Events.trace -> state -> Prop :=
| step_module :
    forall g m st sf ctrl data
      asr asa
      basr1 basa1 nasr1 nasa1
      basr2 basa2 nasr2 nasa2
      basr3 basa3 nasr3 nasa3
      asr' asa'
      f pstval,
      asr!(mod_reset m) = Some (ZToValue 0) ->
      asr!(mod_finish m) = Some (ZToValue 0) ->
      asr!(m.(mod_st)) = Some (posToValue st) ->
      m.(mod_controllogic)!st = Some ctrl ->
      m.(mod_datapath)!st = Some data ->
      Verilog.stmnt_runp f
        (Verilog.mkassociations asr empty_assocmap)
        (Verilog.mkassociations asa (empty_stack m))
        ctrl
        (Verilog.mkassociations basr1 nasr1)
        (Verilog.mkassociations basa1 nasa1) ->
      basr1!(m.(mod_st)) = Some (posToValue st) ->
      Verilog.stmnt_runp f
        (Verilog.mkassociations basr1 nasr1)
        (Verilog.mkassociations basa1 nasa1)
        data
        (Verilog.mkassociations basr2 nasr2)
        (Verilog.mkassociations basa2 nasa2) ->
      exec_ram
        (Verilog.mkassociations (Verilog.merge_regs nasr2 basr2) empty_assocmap)
        (Verilog.mkassociations (Verilog.merge_arrs nasa2 basa2) (empty_stack m))
        (mod_ram m)
        (Verilog.mkassociations basr3 nasr3)
        (Verilog.mkassociations basa3 nasa3) ->
      asr' = Verilog.merge_regs nasr3 basr3 ->
      asa' = Verilog.merge_arrs nasa3 basa3 ->
      asr'!(m.(mod_st)) = Some (posToValue pstval) ->
      (Z.pos pstval <= Integers.Int.max_unsigned)%Z ->
      step g (State sf m st asr asa) Events.E0 (State sf m pstval asr' asa')
| step_finish :
    forall g m st asr asa retval sf,
    asr!(m.(mod_finish)) = Some (ZToValue 1) ->
    asr!(m.(mod_return)) = Some retval ->
    step g (State sf m st asr asa) Events.E0 (Returnstate sf retval)
| step_call :
    forall g m args res,
      step g (Callstate res m args) Events.E0
           (State res m m.(mod_entrypoint)
             (AssocMap.set (mod_reset m) (ZToValue 0)
              (AssocMap.set (mod_finish m) (ZToValue 0)
               (AssocMap.set (mod_st m) (posToValue m.(mod_entrypoint))
                (init_regs args m.(mod_params)))))
             (empty_stack m))
| step_return :
    forall g m asr asa i r sf pc mst,
      mst = mod_st m ->
      step g (Returnstate (Stackframe r m pc asr asa :: sf) i) Events.E0
           (State sf m pc ((asr # mst <- (posToValue pc)) # r <- i) asa).
#[export] Hint Constructors step : htl.

Inductive initial_state (p: program): state -> Prop :=
  | initial_state_intro: forall b m0 m,
      let ge := Globalenvs.Genv.globalenv p in
      Globalenvs.Genv.init_mem p = Some m0 ->
      Globalenvs.Genv.find_symbol ge p.(AST.prog_main) = Some b ->
      Globalenvs.Genv.find_funct_ptr ge b = Some (AST.Internal m) ->
      initial_state p (Callstate nil m nil).

Inductive final_state : state -> Integers.int -> Prop :=
| final_state_intro : forall retval retvali,
    retvali = valueToInt retval ->
    final_state (Returnstate nil retval) retvali.

Definition semantics (m : program) :=
  Smallstep.Semantics step (initial_state m) final_state
                      (Globalenvs.Genv.globalenv m).

Definition all_module_regs m :=
  all_ram_regs (mod_ram m) ++
               (mod_st m::mod_finish m::mod_return m::mod_start m::mod_reset m::mod_clk m::nil).

Definition max_pc_function (m: module) :=
  List.fold_left Pos.max (List.map fst (PTree.elements m.(mod_controllogic))) 1.

Definition max_list := fold_right Pos.max 1.

Definition max_stmnt_tree t :=
  PTree.fold (fun i _ st => Pos.max (Verilog.max_reg_stmnt st) i) t 1.

Definition max_reg_ram r :=
  match r with
  | None => 1
  | Some ram => Pos.max (ram_mem ram)
                (Pos.max (ram_en ram)
                 (Pos.max (ram_addr ram)
                  (Pos.max (ram_addr ram)
                   (Pos.max (ram_wr_en ram)
                    (Pos.max (ram_d_in ram)
                     (Pos.max (ram_d_out ram) (ram_u_en ram)))))))
  end.

Definition max_reg_body m :=
  Pos.max (max_list (mod_params m))
          (Pos.max (max_stmnt_tree (mod_datapath m))
                   (max_stmnt_tree (mod_controllogic m))).

Definition max_reg_module m :=
  Pos.max (max_reg_body m) (max_list (all_module_regs m)).

Record wf_htl_module m :=
  mk_wf_htl_module {
      mod_wf : map_well_formed (mod_controllogic m) /\ map_well_formed (mod_datapath m);
      mod_ordering_wf : list_norepet (all_module_regs m);
      mod_gt : Forall (Pos.lt (max_reg_body m)) (all_module_regs m);
    }.

Lemma max_fold_lt :
  forall m l n, m <= n -> m <= (fold_left Pos.max l n).
Proof. induction l; crush; apply IHl; lia. Qed.

Lemma max_fold_lt2 :
  forall (l: list (positive * Verilog.stmnt)) v n,
    v <= n ->
    v <= fold_left (fun a p => Pos.max (Verilog.max_reg_stmnt (snd p)) a) l n.
Proof. induction l; crush; apply IHl; lia. Qed.

Lemma max_fold_lt3 :
  forall (l: list (positive * Verilog.stmnt)) v v',
    v <= v' ->
    fold_left (fun a0 p => Pos.max (Verilog.max_reg_stmnt (snd p)) a0) l v
    <= fold_left (fun a0 p => Pos.max (Verilog.max_reg_stmnt (snd p)) a0) l v'.
Proof. induction l; crush; apply IHl; lia. Qed.

Lemma max_fold_lt4 :
  forall (l: list (positive * Verilog.stmnt)) (a: positive * Verilog.stmnt),
    fold_left (fun a0 p => Pos.max (Verilog.max_reg_stmnt (snd p)) a0) l 1
    <= fold_left (fun a0 p => Pos.max (Verilog.max_reg_stmnt (snd p)) a0) l
                 (Pos.max (Verilog.max_reg_stmnt (snd a)) 1).
Proof. intros; apply max_fold_lt3; lia. Qed.

Lemma max_reg_stmnt_lt_stmnt_tree':
  forall l (i: positive) v,
    In (i, v) l ->
    list_norepet (map fst l) ->
    Verilog.max_reg_stmnt v <= fold_left (fun a p => Pos.max (Verilog.max_reg_stmnt (snd p)) a) l 1.
Proof.
  induction l; crush. inv H; inv H0; simplify. apply max_fold_lt2. lia.
  transitivity (fold_left (fun (a : positive) (p : positive * Verilog.stmnt) =>
                             Pos.max (Verilog.max_reg_stmnt (snd p)) a) l 1).
  eapply IHl; eauto. apply max_fold_lt4.
Qed.

Lemma max_reg_stmnt_le_stmnt_tree :
  forall d i v,
    d ! i = Some v ->
    Verilog.max_reg_stmnt v <= max_stmnt_tree d.
Proof.
  intros. unfold max_stmnt_tree. rewrite PTree.fold_spec.
  apply PTree.elements_correct in H.
  eapply max_reg_stmnt_lt_stmnt_tree'; eauto.
  apply PTree.elements_keys_norepet.
Qed.

Lemma max_reg_stmnt_lt_stmnt_tree :
  forall d i v,
    d ! i = Some v ->
    Verilog.max_reg_stmnt v < max_stmnt_tree d + 1.
Proof. intros. apply max_reg_stmnt_le_stmnt_tree in H; lia. Qed.

Lemma max_stmnt_lt_module :
  forall m d i,
    wf_htl_module m ->
    (mod_controllogic m) ! i = Some d \/ (mod_datapath m) ! i = Some d ->
    Verilog.max_reg_stmnt d < max_reg_module m + 1.
Proof.
  intros. apply mod_gt in H.
  unfold Pos.lt, max_reg_body, max_reg_module, max_list, all_module_regs, all_ram_regs in *.
  simplify.
  repeat match goal with H: Forall _ _ |- _ => inv H end.
  inversion H0 as [Hv | Hv]; apply max_reg_stmnt_le_stmnt_tree in Hv.
  Admitted.

Lemma max_list_correct l st : st > max_list l -> Forall (Pos.gt st) l.
Proof. induction l; crush; constructor; [|apply IHl]; lia. Qed.

Definition max_list_dec (l: list reg) (st: reg) : {Forall (Pos.gt st) l} + {True}.
  refine (
      match bool_dec (max_list l <? st) true with
      | left _ => left _
      | _ => _
      end
    ); auto.
  apply max_list_correct. apply Pos.ltb_lt in e. lia.
Qed.

Variant wf_htl_fundef: fundef -> Prop :=
  | wf_htl_fundef_external: forall ef,
      wf_htl_fundef (AST.External ef)
  | wf_htl_function_internal: forall f,
      wf_htl_module f ->
      wf_htl_fundef (AST.Internal f).

Definition wf_htl_program (p: program) : Prop :=
  forall f id, In (id, AST.Gfun f) (AST.prog_defs p) -> wf_htl_fundef f.
