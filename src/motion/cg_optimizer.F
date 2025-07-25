!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines for Geometry optimization using  Conjugate Gradients
!> \author Teodoro Laino [teo]
!>      10.2005
! **************************************************************************************************
MODULE cg_optimizer

   USE cell_types, ONLY: cell_type
   USE cg_utils, ONLY: cg_linmin, &
                       get_conjugate_direction
   USE cp_external_control, ONLY: external_control
   USE cp_log_handling, ONLY: cp_get_default_logger, &
                              cp_logger_type
   USE cp_output_handling, ONLY: cp_iterate, &
                                 cp_print_key_finished_output, &
                                 cp_print_key_unit_nr
   USE cp_subsys_types, ONLY: cp_subsys_type
   USE force_env_types, ONLY: force_env_get, &
                              force_env_type
   USE global_types, ONLY: global_environment_type
   USE gopt_f_methods, ONLY: gopt_f_ii, &
                             gopt_f_io, &
                             gopt_f_io_finalize, &
                             gopt_f_io_init, &
                             print_geo_opt_header, &
                             print_geo_opt_nc
   USE gopt_f_types, ONLY: gopt_f_type
   USE gopt_param_types, ONLY: gopt_param_type
   USE input_constants, ONLY: default_cell_direct_id, &
                              default_cell_geo_opt_id, &
                              default_cell_md_id, &
                              default_cell_method_id, &
                              default_minimization_method_id, &
                              default_ts_method_id
   USE input_section_types, ONLY: section_vals_type, &
                                  section_vals_val_get, &
                                  section_vals_val_set
   USE kinds, ONLY: dp
   USE machine, ONLY: m_walltime
   USE message_passing, ONLY: mp_para_env_type
   USE space_groups, ONLY: identify_space_group, &
                           print_spgr, &
                           spgr_apply_rotations_coord, &
                           spgr_apply_rotations_force
   USE space_groups_types, ONLY: spgr_type
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   #:include "gopt_f77_methods.fypp"

   PUBLIC :: geoopt_cg
   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cg_optimizer'

CONTAINS

! **************************************************************************************************
!> \brief Driver for conjugate gradient optimization technique
!> \param force_env ...
!> \param gopt_param ...
!> \param globenv ...
!> \param geo_section ...
!> \param gopt_env ...
!> \param x0 ...
!> \param do_update ...
!> \par History
!>      10.2005 created [tlaino]
!> \author Teodoro Laino
! **************************************************************************************************
   RECURSIVE SUBROUTINE geoopt_cg(force_env, gopt_param, globenv, geo_section, &
                                  gopt_env, x0, do_update)

      TYPE(force_env_type), POINTER                      :: force_env
      TYPE(gopt_param_type), POINTER                     :: gopt_param
      TYPE(global_environment_type), POINTER             :: globenv
      TYPE(section_vals_type), POINTER                   :: geo_section
      TYPE(gopt_f_type), POINTER                         :: gopt_env
      REAL(KIND=dp), DIMENSION(:), POINTER               :: x0
      LOGICAL, INTENT(OUT), OPTIONAL                     :: do_update

      CHARACTER(len=*), PARAMETER                        :: routineN = 'geoopt_cg'

      INTEGER                                            :: handle, output_unit
      LOGICAL                                            :: my_do_update
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(spgr_type), POINTER                           :: spgr

      CALL timeset(routineN, handle)

      NULLIFY (spgr)
      logger => cp_get_default_logger()
      spgr => gopt_env%spgr

      output_unit = cp_print_key_unit_nr(logger, geo_section, "PRINT%PROGRAM_RUN_INFO", &
                                         extension=".geoLog")
      CALL print_geo_opt_header(gopt_env, output_unit, "CONJUGATE GRADIENTS")

      ! find space_group
      CALL force_env_get(force_env, subsys=subsys)
      CALL section_vals_val_get(geo_section, "KEEP_SPACE_GROUP", l_val=spgr%keep_space_group)
      IF (spgr%keep_space_group) THEN
         SELECT CASE (gopt_env%type_id)
         CASE (default_minimization_method_id, default_ts_method_id)
            CALL force_env_get(force_env, subsys=subsys)
            CALL identify_space_group(subsys, geo_section, gopt_env, output_unit)
            CALL spgr_apply_rotations_coord(spgr, x0)
            CALL print_spgr(spgr)
         CASE (default_cell_method_id)
            SELECT CASE (gopt_env%cell_method_id)
            CASE (default_cell_direct_id)
               CALL force_env_get(force_env, subsys=subsys)
               CALL identify_space_group(subsys, geo_section, gopt_env, output_unit)
               CALL spgr_apply_rotations_coord(spgr, x0)
               CALL print_spgr(spgr)
            CASE (default_cell_geo_opt_id)
               spgr%keep_space_group = .FALSE.
            CASE (default_cell_md_id)
               CPABORT("KEEP_SPACE_GROUP not implemented for motion method MD.")
            CASE DEFAULT
               spgr%keep_space_group = .FALSE.
            END SELECT
         CASE DEFAULT
            spgr%keep_space_group = .FALSE.
         END SELECT
      END IF

      CALL cp_cg_main(force_env, x0, gopt_param, output_unit, globenv, &
                      gopt_env, do_update=my_do_update)

      ! show space_group
      CALL section_vals_val_get(geo_section, "SHOW_SPACE_GROUP", l_val=spgr%show_space_group)
      IF (spgr%show_space_group) THEN
         IF (spgr%keep_space_group) THEN
            CALL force_env_get(force_env, subsys=subsys)
         END IF
         CALL identify_space_group(subsys, geo_section, gopt_env, output_unit)
         CALL print_spgr(spgr)
      END IF

      CALL cp_print_key_finished_output(output_unit, logger, geo_section, &
                                        "PRINT%PROGRAM_RUN_INFO")
      IF (PRESENT(do_update)) do_update = my_do_update

      CALL timestop(handle)

   END SUBROUTINE geoopt_cg

! **************************************************************************************************
!> \brief This really performs the conjugate gradients optimization
!> \param force_env ...
!> \param x0 ...
!> \param gopt_param ...
!> \param output_unit ...
!> \param globenv ...
!> \param gopt_env ...
!> \param do_update ...
!> \par History
!>      10.2005 created [tlaino]
!> \author Teodoro Laino
! **************************************************************************************************
   RECURSIVE SUBROUTINE cp_cg_main(force_env, x0, gopt_param, output_unit, globenv, &
                                   gopt_env, do_update)
      TYPE(force_env_type), POINTER                      :: force_env
      REAL(KIND=dp), DIMENSION(:), POINTER               :: x0
      TYPE(gopt_param_type), POINTER                     :: gopt_param
      INTEGER, INTENT(IN)                                :: output_unit
      TYPE(global_environment_type), POINTER             :: globenv
      TYPE(gopt_f_type), POINTER                         :: gopt_env
      LOGICAL, INTENT(OUT), OPTIONAL                     :: do_update

      CHARACTER(len=*), PARAMETER                        :: routineN = 'cp_cg_main'

      CHARACTER(LEN=5)                                   :: wildcard
      INTEGER                                            :: handle, iter_nr, its, max_steep_steps, &
                                                            maxiter
      LOGICAL                                            :: conv, Fletcher_Reeves, &
                                                            save_consistent_energy_force, &
                                                            should_stop
      REAL(KIND=dp)                                      :: emin, eold, opt_energy, res_lim, t_diff, &
                                                            t_now, t_old
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: xold
      REAL(KIND=dp), DIMENSION(:), POINTER               :: g, h, xi
      TYPE(cell_type), POINTER                           :: cell
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(section_vals_type), POINTER                   :: root_section
      TYPE(spgr_type), POINTER                           :: spgr

      CALL timeset(routineN, handle)
      t_old = m_walltime()
      NULLIFY (logger, g, h, xi, spgr)
      root_section => force_env%root_section
      logger => cp_get_default_logger()
      conv = .FALSE.
      maxiter = gopt_param%max_iter
      max_steep_steps = gopt_param%max_steep_steps
      Fletcher_Reeves = gopt_param%Fletcher_Reeves
      res_lim = gopt_param%restart_limit
      ALLOCATE (g(SIZE(x0)))
      ALLOCATE (h(SIZE(x0)))
      ALLOCATE (xi(SIZE(x0)))
      ALLOCATE (xold(SIZE(x0)))
      CALL force_env_get(force_env, cell=cell, subsys=subsys)

      spgr => gopt_env%spgr
      ! applies rotation matrices to coordinates
      IF (spgr%keep_space_group) THEN
         CALL spgr_apply_rotations_coord(spgr, x0)
      END IF

      ! Evaluate energy and forces at the first step
      ![NB] consistent energies and forces not required for CG, but some line minimizers might set it
      save_consistent_energy_force = gopt_env%require_consistent_energy_force
      gopt_env%require_consistent_energy_force = .FALSE.

      CALL cp_eval_at(gopt_env, x0, opt_energy, xi, gopt_env%force_env%para_env%mepos, &
                      .FALSE., gopt_env%force_env%para_env)

      gopt_env%require_consistent_energy_force = save_consistent_energy_force

      ! Symmetrize coordinates and forces
      IF (spgr%keep_space_group) THEN
         CALL spgr_apply_rotations_coord(spgr, x0)
         CALL spgr_apply_rotations_force(spgr, xi)
      END IF

      g = -xi
      h = g
      xi = h
      emin = HUGE(0.0_dp)
      CALL cp_iterate(logger%iter_info, increment=0, iter_nr_out=iter_nr)
      ! Main Loop
      wildcard = "   SD"
      t_now = m_walltime()
      t_diff = t_now - t_old
      t_old = t_now
      CALL gopt_f_io_init(gopt_env, output_unit, opt_energy, wildcard, used_time=t_diff, its=iter_nr)
      eold = opt_energy
      DO its = iter_nr + 1, maxiter
         CALL cp_iterate(logger%iter_info, last=(its == maxiter))
         CALL section_vals_val_set(gopt_env%geo_section, "STEP_START_VAL", i_val=its)
         CALL gopt_f_ii(its, output_unit)

         ! Symmetrize coordinates and forces
         IF (spgr%keep_space_group) THEN
            CALL spgr_apply_rotations_coord(spgr, x0)
            CALL spgr_apply_rotations_force(spgr, g)
            CALL spgr_apply_rotations_force(spgr, xi)
         END IF

         xold(:) = x0

         ! Line minimization
         CALL cg_linmin(gopt_env, x0, xi, g, opt_energy, output_unit, gopt_param, globenv)

         ! Applies rotation matrices to coordinates
         IF (spgr%keep_space_group) THEN
            CALL spgr_apply_rotations_coord(spgr, x0)
         END IF

         ! Check for an external exit command
         CALL external_control(should_stop, "GEO", globenv=globenv)
         IF (should_stop) EXIT

         ! Some IO and Convergence check
         t_now = m_walltime()
         t_diff = t_now - t_old
         t_old = t_now
         CALL gopt_f_io(gopt_env, force_env, root_section, its, opt_energy, &
                        output_unit, eold, emin, wildcard, gopt_param, SIZE(x0), x0 - xold, xi, conv, &
                        used_time=t_diff)
         eold = opt_energy
         emin = MIN(emin, opt_energy)

         IF (conv .OR. (its == maxiter)) EXIT
         ![NB] consistent energies and forces not required for CG, but some line minimizers might set it
         save_consistent_energy_force = gopt_env%require_consistent_energy_force
         gopt_env%require_consistent_energy_force = .FALSE.

         CALL cp_eval_at(gopt_env, x0, opt_energy, xi, gopt_env%force_env%para_env%mepos, &
                         .FALSE., gopt_env%force_env%para_env)

         gopt_env%require_consistent_energy_force = save_consistent_energy_force

         ! Symmetrize coordinates and forces
         IF (spgr%keep_space_group) THEN
            CALL spgr_apply_rotations_force(spgr, xi)
         END IF

         ! Get Conjugate Directions:  updates the searching direction (h)
         wildcard = "   CG"
         CALL get_conjugate_direction(gopt_env, Fletcher_Reeves, g, xi, h)

         ! Symmetrize coordinates and forces
         IF (spgr%keep_space_group) THEN
            CALL spgr_apply_rotations_force(spgr, g)
            CALL spgr_apply_rotations_force(spgr, h)
         END IF

         ! Reset Condition or Steepest Descent Requested
         ! ABS(DOT_PRODUCT(g, h))/SQRT((DOT_PRODUCT(g, g)*DOT_PRODUCT(h, h))) > res_lim ...
         IF ((DOT_PRODUCT(g, h)*DOT_PRODUCT(g, h)) > (res_lim*res_lim*DOT_PRODUCT(g, g)*DOT_PRODUCT(h, h)) &
             .OR. its + 1 <= max_steep_steps) THEN
            ! Steepest Descent
            wildcard = "   SD"
            h = -xi
         END IF
         g = -xi
         xi = h
      END DO

      IF (its == maxiter .AND. (.NOT. conv)) THEN
         CALL print_geo_opt_nc(gopt_env, output_unit)
      END IF

      ! Write final particle information and restart, if converged
      IF (PRESENT(do_update)) do_update = conv
      CALL cp_iterate(logger%iter_info, last=.TRUE., increment=0)
      CALL gopt_f_io_finalize(gopt_env, force_env, x0, conv, its, root_section, &
                              gopt_env%force_env%para_env, gopt_env%force_env%para_env%mepos, output_unit)

      DEALLOCATE (xold)
      DEALLOCATE (g)
      DEALLOCATE (h)
      DEALLOCATE (xi)

      CALL timestop(handle)

   END SUBROUTINE cp_cg_main

END MODULE cg_optimizer
