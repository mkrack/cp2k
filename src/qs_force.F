!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Quickstep force driver routine
!> \author MK (12.06.2002)
! **************************************************************************************************
MODULE qs_force
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind_set
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_api,                    ONLY: dbcsr_copy,&
                                              dbcsr_p_type,&
                                              dbcsr_set
   USE cp_dbcsr_operations,             ONLY: dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_dbcsr_output,                 ONLY: cp_dbcsr_write_sparse_matrix
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_io_unit,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_p_file,&
                                              cp_print_key_finished_output,&
                                              cp_print_key_should_output,&
                                              cp_print_key_unit_nr
   USE dft_plus_u,                      ONLY: plus_u
   USE ec_env_types,                    ONLY: energy_correction_type
   USE efield_utils,                    ONLY: calculate_ecore_efield,&
                                              efield_potential_lengh_gauge
   USE energy_corrections,              ONLY: energy_correction
   USE excited_states,                  ONLY: excited_state_energy
   USE hfx_exx,                         ONLY: calculate_exx
   USE input_constants,                 ONLY: ri_mp2_laplace,&
                                              ri_mp2_method_gpw,&
                                              ri_rpa_method_gpw
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE lri_environment_types,           ONLY: lri_environment_type
   USE message_passing,                 ONLY: mp_para_env_type
   USE mp2_cphf,                        ONLY: update_mp2_forces
   USE mulliken,                        ONLY: mulliken_restraint
   USE particle_types,                  ONLY: particle_type
   USE qs_core_energies,                ONLY: calculate_ecore_overlap,&
                                              calculate_ecore_self
   USE qs_core_hamiltonian,             ONLY: build_core_hamiltonian_matrix
   USE qs_dftb_dispersion,              ONLY: calculate_dftb_dispersion
   USE qs_dftb_matrices,                ONLY: build_dftb_matrices
   USE qs_energy,                       ONLY: qs_energies
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_methods,          ONLY: qs_env_rebuild_pw_env
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_external_potential,           ONLY: external_c_potential,&
                                              external_e_potential
   USE qs_force_types,                  ONLY: allocate_qs_force,&
                                              qs_force_type,&
                                              replicate_qs_force,&
                                              zero_qs_force
   USE qs_ks_methods,                   ONLY: qs_ks_update_qs_env
   USE qs_ks_types,                     ONLY: qs_ks_env_type,&
                                              set_ks_env
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE qs_scf_post_scf,                 ONLY: qs_scf_compute_properties
   USE qs_subsys_types,                 ONLY: qs_subsys_set,&
                                              qs_subsys_type
   USE ri_environment_methods,          ONLY: build_ri_matrices
   USE rt_propagation_forces,           ONLY: calc_c_mat_force,&
                                              rt_admm_force
   USE rt_propagation_velocity_gauge,   ONLY: velocity_gauge_ks_matrix,&
                                              velocity_gauge_nl_force
   USE se_core_core,                    ONLY: se_core_core_interaction
   USE se_core_matrix,                  ONLY: build_se_core_matrix
   USE tblite_interface,                ONLY: build_tblite_matrices
   USE virial_types,                    ONLY: symmetrize_virial,&
                                              virial_type
   USE xtb_matrices,                    ONLY: build_xtb_matrices
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! *** Global parameters ***

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_force'

! *** Public subroutines ***

   PUBLIC :: qs_calc_energy_force

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
!> \param calc_force ...
!> \param consistent_energies ...
!> \param linres ...
! **************************************************************************************************
   SUBROUTINE qs_calc_energy_force(qs_env, calc_force, consistent_energies, linres)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      LOGICAL                                            :: calc_force, consistent_energies, linres

      qs_env%linres_run = linres
      IF (calc_force) THEN
         CALL qs_forces(qs_env)
      ELSE
         CALL qs_energies(qs_env, calc_forces=.FALSE., &
                          consistent_energies=consistent_energies)
      END IF

   END SUBROUTINE qs_calc_energy_force

! **************************************************************************************************
!> \brief   Calculate the Quickstep forces.
!> \param qs_env ...
!> \date    29.10.2002
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE qs_forces(qs_env)

      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'qs_forces'

      INTEGER                                            :: after, handle, i, iatom, ic, ikind, &
                                                            ispin, iw, natom, nkind, nspin, &
                                                            output_unit
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: atom_of_kind, kind_of, natom_of_kind
      LOGICAL                                            :: do_admm, do_exx, do_gw, do_im_time, &
                                                            has_unit_metric, omit_headers, &
                                                            perform_ec, reuse_hfx
      REAL(dp)                                           :: dummy_real, dummy_real2(2)
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s, matrix_w, rho_ao
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_w_kp
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(energy_correction_type), POINTER              :: ec_env
      TYPE(lri_environment_type), POINTER                :: lri_env
      TYPE(mp_para_env_type), POINTER                    :: para_env
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(qs_force_type), DIMENSION(:), POINTER         :: force
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(qs_subsys_type), POINTER                      :: subsys
      TYPE(section_vals_type), POINTER                   :: hfx_sections, print_section
      TYPE(virial_type), POINTER                         :: virial

      CALL timeset(routineN, handle)
      NULLIFY (logger)
      logger => cp_get_default_logger()

      ! rebuild plane wave environment
      CALL qs_env_rebuild_pw_env(qs_env)

      ! zero out the forces in particle set
      CALL get_qs_env(qs_env, particle_set=particle_set)
      natom = SIZE(particle_set)
      DO iatom = 1, natom
         particle_set(iatom)%f = 0.0_dp
      END DO

      ! get atom mapping
      NULLIFY (atomic_kind_set)
      CALL get_qs_env(qs_env, atomic_kind_set=atomic_kind_set)
      CALL get_atomic_kind_set(atomic_kind_set=atomic_kind_set, &
                               atom_of_kind=atom_of_kind, &
                               kind_of=kind_of)

      NULLIFY (force, subsys, dft_control)
      CALL get_qs_env(qs_env, &
                      force=force, &
                      subsys=subsys, &
                      dft_control=dft_control)
      IF (.NOT. ASSOCIATED(force)) THEN
         !   *** Allocate the force data structure ***
         nkind = SIZE(atomic_kind_set)
         CALL get_atomic_kind_set(atomic_kind_set=atomic_kind_set, natom_of_kind=natom_of_kind)
         CALL allocate_qs_force(force, natom_of_kind)
         DEALLOCATE (natom_of_kind)
         CALL qs_subsys_set(subsys, force=force)
      END IF
      CALL zero_qs_force(force)

      ! Check if CDFT potential is needed and save it until forces have been calculated
      IF (dft_control%qs_control%cdft) THEN
         dft_control%qs_control%cdft_control%save_pot = .TRUE.
      END IF

      ! recalculate energy with forces
      CALL qs_energies(qs_env, calc_forces=.TRUE.)

      NULLIFY (para_env)
      CALL get_qs_env(qs_env, &
                      para_env=para_env)

      ! Now we handle some special cases
      ! Maybe some of these would be better dealt with in qs_energies?
      IF (qs_env%run_rtp) THEN
         NULLIFY (matrix_w, matrix_s, ks_env)
         CALL get_qs_env(qs_env, &
                         ks_env=ks_env, &
                         matrix_w=matrix_w, &
                         matrix_s=matrix_s)
         CALL dbcsr_allocate_matrix_set(matrix_w, dft_control%nspins)
         DO ispin = 1, dft_control%nspins
            ALLOCATE (matrix_w(ispin)%matrix)
            CALL dbcsr_copy(matrix_w(ispin)%matrix, matrix_s(1)%matrix, &
                            name="W MATRIX")
            CALL dbcsr_set(matrix_w(ispin)%matrix, 0.0_dp)
         END DO
         CALL set_ks_env(ks_env, matrix_w=matrix_w)

         CALL calc_c_mat_force(qs_env)
         IF (dft_control%do_admm) CALL rt_admm_force(qs_env)
         IF (dft_control%rtp_control%velocity_gauge .AND. dft_control%rtp_control%nl_gauge_transform) &
            CALL velocity_gauge_nl_force(qs_env, particle_set)
      END IF
      ! from an eventual Mulliken restraint
      IF (dft_control%qs_control%mulliken_restraint) THEN
         NULLIFY (matrix_w, matrix_s, rho)
         CALL get_qs_env(qs_env, &
                         matrix_w=matrix_w, &
                         matrix_s=matrix_s, &
                         rho=rho)
         NULLIFY (rho_ao)
         CALL qs_rho_get(rho, rho_ao=rho_ao)
         CALL mulliken_restraint(dft_control%qs_control%mulliken_restraint_control, &
                                 para_env, matrix_s(1)%matrix, rho_ao, w_matrix=matrix_w)
      END IF
      ! Add non-Pulay contribution of DFT+U to W matrix, since it has also to be
      ! digested with overlap matrix derivatives
      IF (dft_control%dft_plus_u) THEN
         NULLIFY (matrix_w)
         CALL get_qs_env(qs_env, matrix_w=matrix_w)
         CALL plus_u(qs_env=qs_env, matrix_w=matrix_w)
      END IF

      ! Write W Matrix to output (if requested)
      CALL get_qs_env(qs_env, has_unit_metric=has_unit_metric)
      IF (.NOT. has_unit_metric) THEN
         NULLIFY (matrix_w_kp)
         CALL get_qs_env(qs_env, matrix_w_kp=matrix_w_kp)
         nspin = SIZE(matrix_w_kp, 1)
         DO ispin = 1, nspin
            IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                                 qs_env%input, "DFT%PRINT%AO_MATRICES/W_MATRIX"), cp_p_file)) THEN
               iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%AO_MATRICES/W_MATRIX", &
                                         extension=".Log")
               CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
               CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%OMIT_HEADERS", l_val=omit_headers)
               after = MIN(MAX(after, 1), 16)
               DO ic = 1, SIZE(matrix_w_kp, 2)
                  CALL cp_dbcsr_write_sparse_matrix(matrix_w_kp(ispin, ic)%matrix, 4, after, qs_env, &
                                                    para_env, output_unit=iw, omit_headers=omit_headers)
               END DO
               CALL cp_print_key_finished_output(iw, logger, qs_env%input, &
                                                 "DFT%PRINT%AO_MATRICES/W_MATRIX")
            END IF
         END DO
      END IF

      ! Check if energy correction should be skipped
      perform_ec = .FALSE.
      IF (qs_env%energy_correction) THEN
         CALL get_qs_env(qs_env, ec_env=ec_env)
         IF (.NOT. ec_env%do_skip) perform_ec = .TRUE.
      END IF

      ! Compute core forces (also overwrites matrix_w)
      IF (dft_control%qs_control%semi_empirical) THEN
         CALL build_se_core_matrix(qs_env=qs_env, para_env=para_env, &
                                   calculate_forces=.TRUE.)
         CALL se_core_core_interaction(qs_env, para_env, calculate_forces=.TRUE.)
      ELSEIF (dft_control%qs_control%dftb) THEN
         CALL build_dftb_matrices(qs_env=qs_env, para_env=para_env, &
                                  calculate_forces=.TRUE.)
         CALL calculate_dftb_dispersion(qs_env=qs_env, para_env=para_env, &
                                        calculate_forces=.TRUE.)
      ELSEIF (dft_control%qs_control%xtb) THEN
         IF (dft_control%qs_control%xtb_control%do_tblite) THEN
            CALL build_tblite_matrices(qs_env=qs_env, calculate_forces=.TRUE.)
         ELSE
            CALL build_xtb_matrices(qs_env=qs_env, calculate_forces=.TRUE.)
         END IF
      ELSEIF (perform_ec) THEN
         ! Calculates core and grid based forces
         CALL energy_correction(qs_env, ec_init=.FALSE., calculate_forces=.TRUE.)
      ELSE
         ! Dispersion energy and forces are calculated in qs_energy?
         CALL build_core_hamiltonian_matrix(qs_env=qs_env, calculate_forces=.TRUE.)
         ! The above line reset the core H, which should be re-updated in case a TD field is applied:
         IF (qs_env%run_rtp) THEN
            IF (dft_control%apply_efield_field) &
               CALL efield_potential_lengh_gauge(qs_env)
            IF (dft_control%rtp_control%velocity_gauge) &
               CALL velocity_gauge_ks_matrix(qs_env, subtract_nl_term=.FALSE.)

         END IF
         CALL calculate_ecore_self(qs_env)
         CALL calculate_ecore_overlap(qs_env, para_env, calculate_forces=.TRUE.)
         CALL calculate_ecore_efield(qs_env, calculate_forces=.TRUE.)
         !swap external_e_potential before external_c_potential, to ensure
         !that external potential on grid is loaded before calculating energy of cores
         CALL external_e_potential(qs_env)
         IF (.NOT. dft_control%qs_control%gapw) THEN
            CALL external_c_potential(qs_env, calculate_forces=.TRUE.)
         END IF
         ! RIGPW  matrices
         IF (dft_control%qs_control%rigpw) THEN
            CALL get_qs_env(qs_env=qs_env, lri_env=lri_env)
            CALL build_ri_matrices(lri_env, qs_env, calculate_forces=.TRUE.)
         END IF
      END IF

      ! MP2 Code
      IF (ASSOCIATED(qs_env%mp2_env)) THEN
         NULLIFY (energy)
         CALL get_qs_env(qs_env, energy=energy)
         CALL qs_scf_compute_properties(qs_env, wf_type='MP2   ', do_mp2=.TRUE.)
         CALL qs_ks_update_qs_env(qs_env, just_energy=.TRUE.)
         energy%total = energy%total + energy%mp2

         IF ((qs_env%mp2_env%method == ri_mp2_method_gpw .OR. qs_env%mp2_env%method == ri_mp2_laplace .OR. &
              qs_env%mp2_env%method == ri_rpa_method_gpw) &
             .AND. .NOT. qs_env%mp2_env%do_im_time) THEN
            CALL update_mp2_forces(qs_env)
         END IF

         !RPA EXX energy and forces
         IF (qs_env%mp2_env%method == ri_rpa_method_gpw) THEN
            do_exx = .FALSE.
            hfx_sections => section_vals_get_subs_vals(qs_env%input, "DFT%XC%WF_CORRELATION%RI_RPA%HF")
            CALL section_vals_get(hfx_sections, explicit=do_exx)
            IF (do_exx) THEN
               do_gw = qs_env%mp2_env%ri_rpa%do_ri_g0w0
               do_admm = qs_env%mp2_env%ri_rpa%do_admm
               reuse_hfx = qs_env%mp2_env%ri_rpa%reuse_hfx
               do_im_time = qs_env%mp2_env%do_im_time
               output_unit = cp_logger_get_default_io_unit()
               dummy_real = 0.0_dp

               CALL calculate_exx(qs_env=qs_env, &
                                  unit_nr=output_unit, &
                                  hfx_sections=hfx_sections, &
                                  x_data=qs_env%mp2_env%ri_rpa%x_data, &
                                  do_gw=do_gw, &
                                  do_admm=do_admm, &
                                  calc_forces=.TRUE., &
                                  reuse_hfx=reuse_hfx, &
                                  do_im_time=do_im_time, &
                                  E_ex_from_GW=dummy_real, &
                                  E_admm_from_GW=dummy_real2, &
                                  t3=dummy_real)
            END IF
         END IF
      ELSEIF (perform_ec) THEN
         ! energy correction forces postponed
      ELSEIF (qs_env%harris_method) THEN
         ! Harris method forces already done in harris_energy_correction
      ELSE
         ! Compute grid-based forces
         CALL qs_ks_update_qs_env(qs_env, calculate_forces=.TRUE.)
      END IF

      ! Excited state forces
      CALL excited_state_energy(qs_env, calculate_forces=.TRUE.)

      ! replicate forces (get current pointer)
      NULLIFY (force)
      CALL get_qs_env(qs_env=qs_env, force=force)
      CALL replicate_qs_force(force, para_env)

      DO iatom = 1, natom
         ikind = kind_of(iatom)
         i = atom_of_kind(iatom)
         ! XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
         ! the force is - dE/dR, what is called force is actually the gradient
         ! Things should have the right name
         ! The minus sign below is a hack
         ! XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
         force(ikind)%other(1:3, i) = -particle_set(iatom)%f(1:3) + force(ikind)%ch_pulay(1:3, i)
         force(ikind)%total(1:3, i) = force(ikind)%total(1:3, i) + force(ikind)%other(1:3, i)
         particle_set(iatom)%f = -force(ikind)%total(1:3, i)
      END DO

      NULLIFY (virial, energy)
      CALL get_qs_env(qs_env=qs_env, virial=virial, energy=energy)
      IF (virial%pv_availability) THEN
         CALL para_env%sum(virial%pv_overlap)
         CALL para_env%sum(virial%pv_ekinetic)
         CALL para_env%sum(virial%pv_ppl)
         CALL para_env%sum(virial%pv_ppnl)
         CALL para_env%sum(virial%pv_ecore_overlap)
         CALL para_env%sum(virial%pv_ehartree)
         CALL para_env%sum(virial%pv_exc)
         CALL para_env%sum(virial%pv_exx)
         CALL para_env%sum(virial%pv_vdw)
         CALL para_env%sum(virial%pv_mp2)
         CALL para_env%sum(virial%pv_nlcc)
         CALL para_env%sum(virial%pv_gapw)
         CALL para_env%sum(virial%pv_lrigpw)
         CALL para_env%sum(virial%pv_virial)
         CALL symmetrize_virial(virial)
         ! Add the volume terms of the virial
         IF ((.NOT. virial%pv_numer) .AND. &
             (.NOT. (dft_control%qs_control%dftb .OR. &
                     dft_control%qs_control%xtb .OR. &
                     dft_control%qs_control%semi_empirical))) THEN

            ! Harris energy correction requires volume terms from
            ! 1) Harris functional contribution, and
            ! 2) Linear Response solver
            IF (perform_ec) THEN
               CALL get_qs_env(qs_env, ec_env=ec_env)
               energy%hartree = ec_env%ehartree
               energy%exc = ec_env%exc
               IF (dft_control%do_admm) THEN
                  energy%exc_aux_fit = ec_env%exc_aux_fit
               END IF
            END IF
            DO i = 1, 3
               virial%pv_ehartree(i, i) = virial%pv_ehartree(i, i) &
                                          - 2.0_dp*(energy%hartree + energy%sccs_pol)
               virial%pv_virial(i, i) = virial%pv_virial(i, i) - energy%exc &
                                        - 2.0_dp*(energy%hartree + energy%sccs_pol)
               virial%pv_exc(i, i) = virial%pv_exc(i, i) - energy%exc
               IF (dft_control%do_admm) THEN
                  virial%pv_exc(i, i) = virial%pv_exc(i, i) - energy%exc_aux_fit
                  virial%pv_virial(i, i) = virial%pv_virial(i, i) - energy%exc_aux_fit
               END IF
               ! The factor 2 is a hack. It compensates the plus sign in h_stress/pw_poisson_solve.
               ! The sign in pw_poisson_solve is correct for FIST, but not for QS.
               ! There should be a more elegant solution to that ...
            END DO
         END IF
      END IF

      output_unit = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%DERIVATIVES", &
                                         extension=".Log")
      print_section => section_vals_get_subs_vals(qs_env%input, "DFT%PRINT%DERIVATIVES")
      IF (dft_control%qs_control%semi_empirical) THEN
         CALL write_forces(force, atomic_kind_set, 2, output_unit=output_unit, &
                           print_section=print_section)
      ELSE IF (dft_control%qs_control%dftb) THEN
         CALL write_forces(force, atomic_kind_set, 4, output_unit=output_unit, &
                           print_section=print_section)
      ELSE IF (dft_control%qs_control%xtb) THEN
         CALL write_forces(force, atomic_kind_set, 4, output_unit=output_unit, &
                           print_section=print_section)
      ELSE IF (dft_control%qs_control%gapw .OR. dft_control%qs_control%gapw_xc) THEN
         CALL write_forces(force, atomic_kind_set, 1, output_unit=output_unit, &
                           print_section=print_section)
      ELSE
         CALL write_forces(force, atomic_kind_set, 0, output_unit=output_unit, &
                           print_section=print_section)
      END IF
      CALL cp_print_key_finished_output(output_unit, logger, qs_env%input, &
                                        "DFT%PRINT%DERIVATIVES")

      ! deallocate W Matrix:
      NULLIFY (ks_env, matrix_w_kp)
      CALL get_qs_env(qs_env=qs_env, &
                      matrix_w_kp=matrix_w_kp, &
                      ks_env=ks_env)
      CALL dbcsr_deallocate_matrix_set(matrix_w_kp)
      NULLIFY (matrix_w_kp)
      CALL set_ks_env(ks_env, matrix_w_kp=matrix_w_kp)

      DEALLOCATE (atom_of_kind, kind_of)

      CALL timestop(handle)

   END SUBROUTINE qs_forces

! **************************************************************************************************
!> \brief   Write a Quickstep force data structure to output unit
!> \param qs_force ...
!> \param atomic_kind_set ...
!> \param ftype ...
!> \param output_unit ...
!> \param print_section ...
!> \date    05.06.2002
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE write_forces(qs_force, atomic_kind_set, ftype, output_unit, &
                           print_section)

      TYPE(qs_force_type), DIMENSION(:), POINTER         :: qs_force
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      INTEGER, INTENT(IN)                                :: ftype, output_unit
      TYPE(section_vals_type), POINTER                   :: print_section

      CHARACTER(LEN=13)                                  :: fmtstr5
      CHARACTER(LEN=15)                                  :: fmtstr4
      CHARACTER(LEN=20)                                  :: fmtstr3
      CHARACTER(LEN=35)                                  :: fmtstr2
      CHARACTER(LEN=48)                                  :: fmtstr1
      INTEGER                                            :: i, iatom, ikind, my_ftype, natom, ndigits
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: atom_of_kind, kind_of
      REAL(KIND=dp), DIMENSION(3)                        :: grand_total

      IF (output_unit > 0) THEN

         IF (.NOT. ASSOCIATED(qs_force)) THEN
            CALL cp_abort(__LOCATION__, &
                          "The qs_force pointer is not associated "// &
                          "and cannot be printed")
         END IF

         CALL get_atomic_kind_set(atomic_kind_set=atomic_kind_set, atom_of_kind=atom_of_kind, &
                                  kind_of=kind_of, natom=natom)

         ! Variable precision output of the forces
         CALL section_vals_val_get(print_section, "NDIGITS", &
                                   i_val=ndigits)

         fmtstr1 = "(/,/,T2,A,/,/,T3,A,T11,A,T23,A,T40,A1,2(  X,A1))"
         WRITE (UNIT=fmtstr1(41:42), FMT="(I2)") ndigits + 5

         fmtstr2 = "(/,(T2,I5,4X,I4,T18,A,T34,3F  .  ))"
         WRITE (UNIT=fmtstr2(32:33), FMT="(I2)") ndigits
         WRITE (UNIT=fmtstr2(29:30), FMT="(I2)") ndigits + 6

         fmtstr3 = "(/,T3,A,T34,3F  .  )"
         WRITE (UNIT=fmtstr3(18:19), FMT="(I2)") ndigits
         WRITE (UNIT=fmtstr3(15:16), FMT="(I2)") ndigits + 6

         fmtstr4 = "((T34,3F  .  ))"
         WRITE (UNIT=fmtstr4(12:13), FMT="(I2)") ndigits
         WRITE (UNIT=fmtstr4(9:10), FMT="(I2)") ndigits + 6

         fmtstr5 = "(/T2,A//T3,A)"

         WRITE (UNIT=output_unit, FMT=fmtstr1) &
            "FORCES [a.u.]", "Atom", "Kind", "Component", "X", "Y", "Z"

         grand_total(:) = 0.0_dp

         my_ftype = ftype

         SELECT CASE (my_ftype)
         CASE DEFAULT
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, "         total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         CASE (0)
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, "       overlap", qs_force(ikind)%overlap(1:3, i), &
                  iatom, ikind, "  overlap_admm", qs_force(ikind)%overlap_admm(1:3, i), &
                  iatom, ikind, "       kinetic", qs_force(ikind)%kinetic(1:3, i), &
                  iatom, ikind, "       gth_ppl", qs_force(ikind)%gth_ppl(1:3, i), &
                  iatom, ikind, "      gth_nlcc", qs_force(ikind)%gth_nlcc(1:3, i), &
                  iatom, ikind, "      gth_ppnl", qs_force(ikind)%gth_ppnl(1:3, i), &
                  iatom, ikind, "  core_overlap", qs_force(ikind)%core_overlap(1:3, i), &
                  iatom, ikind, "      rho_core", qs_force(ikind)%rho_core(1:3, i), &
                  iatom, ikind, "      rho_elec", qs_force(ikind)%rho_elec(1:3, i), &
                  iatom, ikind, "  rho_lri_elec", qs_force(ikind)%rho_lri_elec(1:3, i), &
                  iatom, ikind, "      ch_pulay", qs_force(ikind)%ch_pulay(1:3, i), &
                  iatom, ikind, "    dispersion", qs_force(ikind)%dispersion(1:3, i), &
                  iatom, ikind, "           gCP", qs_force(ikind)%gcp(1:3, i), &
                  iatom, ikind, "         other", qs_force(ikind)%other(1:3, i), &
                  iatom, ikind, "       fock_4c", qs_force(ikind)%fock_4c(1:3, i), &
                  iatom, ikind, "     ehrenfest", qs_force(ikind)%ehrenfest(1:3, i), &
                  iatom, ikind, "        efield", qs_force(ikind)%efield(1:3, i), &
                  iatom, ikind, "           eev", qs_force(ikind)%eev(1:3, i), &
                  iatom, ikind, "   mp2_non_sep", qs_force(ikind)%mp2_non_sep(1:3, i), &
                  iatom, ikind, "         total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         CASE (1)
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, "       overlap", qs_force(ikind)%overlap(1:3, i), &
                  iatom, ikind, "  overlap_admm", qs_force(ikind)%overlap_admm(1:3, i), &
                  iatom, ikind, "       kinetic", qs_force(ikind)%kinetic(1:3, i), &
                  iatom, ikind, "       gth_ppl", qs_force(ikind)%gth_ppl(1:3, i), &
                  iatom, ikind, "      gth_nlcc", qs_force(ikind)%gth_nlcc(1:3, i), &
                  iatom, ikind, "      gth_ppnl", qs_force(ikind)%gth_ppnl(1:3, i), &
                  iatom, ikind, " all_potential", qs_force(ikind)%all_potential(1:3, i), &
                  iatom, ikind, "  core_overlap", qs_force(ikind)%core_overlap(1:3, i), &
                  iatom, ikind, "      rho_core", qs_force(ikind)%rho_core(1:3, i), &
                  iatom, ikind, "      rho_elec", qs_force(ikind)%rho_elec(1:3, i), &
                  iatom, ikind, "  rho_lri_elec", qs_force(ikind)%rho_lri_elec(1:3, i), &
                  iatom, ikind, "     vhxc_atom", qs_force(ikind)%vhxc_atom(1:3, i), &
                  iatom, ikind, "   g0s_Vh_elec", qs_force(ikind)%g0s_Vh_elec(1:3, i), &
                  iatom, ikind, "      ch_pulay", qs_force(ikind)%ch_pulay(1:3, i), &
                  iatom, ikind, "    dispersion", qs_force(ikind)%dispersion(1:3, i), &
                  iatom, ikind, "           gCP", qs_force(ikind)%gcp(1:3, i), &
                  iatom, ikind, "       fock_4c", qs_force(ikind)%fock_4c(1:3, i), &
                  iatom, ikind, "     ehrenfest", qs_force(ikind)%ehrenfest(1:3, i), &
                  iatom, ikind, "        efield", qs_force(ikind)%efield(1:3, i), &
                  iatom, ikind, "           eev", qs_force(ikind)%eev(1:3, i), &
                  iatom, ikind, "   mp2_non_sep", qs_force(ikind)%mp2_non_sep(1:3, i), &
                  iatom, ikind, "         total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         CASE (2)
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, " all_potential", qs_force(ikind)%all_potential(1:3, i), &
                  iatom, ikind, "      rho_elec", qs_force(ikind)%rho_elec(1:3, i), &
                  iatom, ikind, "         total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         CASE (3)
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, "        overlap", qs_force(ikind)%overlap(1:3, i), &
                  iatom, ikind, "overlap_admm", qs_force(ikind)%overlap_admm(1:3, i), &
                  iatom, ikind, "        kinetic", qs_force(ikind)%kinetic(1:3, i), &
                  iatom, ikind, "        gth_ppl", qs_force(ikind)%gth_ppl(1:3, i), &
                  iatom, ikind, "       gth_nlcc", qs_force(ikind)%gth_nlcc(1:3, i), &
                  iatom, ikind, "       gth_ppnl", qs_force(ikind)%gth_ppnl(1:3, i), &
                  iatom, ikind, "   core_overlap", qs_force(ikind)%core_overlap(1:3, i), &
                  iatom, ikind, "       rho_core", qs_force(ikind)%rho_core(1:3, i), &
                  iatom, ikind, "       rho_elec", qs_force(ikind)%rho_elec(1:3, i), &
                  iatom, ikind, "       ch_pulay", qs_force(ikind)%ch_pulay(1:3, i), &
                  iatom, ikind, "        fock_4c", qs_force(ikind)%fock_4c(1:3, i), &
                  iatom, ikind, "   mp2_non_sep", qs_force(ikind)%mp2_non_sep(1:3, i), &
                  iatom, ikind, "          total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         CASE (4)
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, "  all_potential", qs_force(ikind)%all_potential(1:3, i), &
                  iatom, ikind, "        overlap", qs_force(ikind)%overlap(1:3, i), &
                  iatom, ikind, "       rho_elec", qs_force(ikind)%rho_elec(1:3, i), &
                  iatom, ikind, "      repulsive", qs_force(ikind)%repulsive(1:3, i), &
                  iatom, ikind, "     dispersion", qs_force(ikind)%dispersion(1:3, i), &
                  iatom, ikind, "        efield", qs_force(ikind)%efield(1:3, i), &
                  iatom, ikind, "     ehrenfest", qs_force(ikind)%ehrenfest(1:3, i), &
                  iatom, ikind, "          total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         CASE (5)
            DO iatom = 1, natom
               ikind = kind_of(iatom)
               i = atom_of_kind(iatom)
               WRITE (UNIT=output_unit, FMT=fmtstr2) &
                  iatom, ikind, "       overlap", qs_force(ikind)%overlap(1:3, i), &
                  iatom, ikind, "       kinetic", qs_force(ikind)%kinetic(1:3, i), &
                  iatom, ikind, "      rho_elec", qs_force(ikind)%rho_elec(1:3, i), &
                  iatom, ikind, "    dispersion", qs_force(ikind)%dispersion(1:3, i), &
                  iatom, ikind, " all potential", qs_force(ikind)%all_potential(1:3, i), &
                  iatom, ikind, "         other", qs_force(ikind)%other(1:3, i), &
                  iatom, ikind, "         total", qs_force(ikind)%total(1:3, i)
               grand_total(1:3) = grand_total(1:3) + qs_force(ikind)%total(1:3, i)
            END DO
         END SELECT

         WRITE (UNIT=output_unit, FMT=fmtstr3) "Sum of total", grand_total(1:3)

         DEALLOCATE (atom_of_kind)
         DEALLOCATE (kind_of)

      END IF

   END SUBROUTINE write_forces

END MODULE qs_force
