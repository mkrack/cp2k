!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \par History
!>      give the md_env its own para_env Joost VandeVondele 07.2003
!>      Teodoro Laino - 09.2007 - University of Zurich - generalizing thermostats
!>                                and barostats
!> \author CJM SEPT-12-02
! **************************************************************************************************
MODULE md_environment_types
   USE averages_types,                  ONLY: average_quantities_type,&
                                              create_averages,&
                                              release_averages,&
                                              retain_averages
   USE barostat_types,                  ONLY: barostat_type,&
                                              release_barostat_type
   USE cell_types,                      ONLY: cell_type
   USE extended_system_types,           ONLY: npt_info_type
   USE force_env_types,                 ONLY: force_env_release,&
                                              force_env_retain,&
                                              force_env_type
   USE free_energy_types,               ONLY: fe_env_release,&
                                              free_energy_type
   USE input_constants,                 ONLY: do_thermo_al,&
                                              langevin_ensemble
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type
   USE kinds,                           ONLY: dp
   USE md_ener_types,                   ONLY: md_ener_type,&
                                              release_md_ener
   USE message_passing,                 ONLY: mp_para_env_release,&
                                              mp_para_env_type
   USE reftraj_types,                   ONLY: reftraj_type,&
                                              release_reftraj
   USE simpar_types,                    ONLY: simpar_type
   USE thermal_region_types,            ONLY: release_thermal_regions,&
                                              thermal_regions_type
   USE thermostat_types,                ONLY: release_thermostats,&
                                              thermostat_type,&
                                              thermostats_type
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! **************************************************************************************************
   TYPE md_environment_type
      ! para_env is the parallel environment of the MD,  i.e. the systems
      ! that are dealt with by the integrator e.g in the PIMD this could
      ! be parent of every bead.
      PRIVATE
      LOGICAL                                    :: init = .FALSE., first_time = .FALSE., ehrenfest_md = .FALSE.
      INTEGER, POINTER                           :: itimes => NULL()
      REAL(KIND=dp), POINTER                     :: used_time => NULL(), t => NULL()
      REAL(KIND=dp), POINTER                     :: constant => NULL()
      TYPE(mp_para_env_type), POINTER            :: para_env => NULL()
      TYPE(cell_type), POINTER                   :: cell => NULL()
      TYPE(force_env_type), POINTER              :: force_env => NULL()
      TYPE(md_ener_type), POINTER                :: md_ener => NULL()
      TYPE(thermostats_type), POINTER            :: thermostats => NULL()
      TYPE(barostat_type), POINTER               :: barostat => NULL()
      TYPE(reftraj_type), POINTER                :: reftraj => NULL()
      TYPE(free_energy_type), POINTER           :: fe_env => NULL()
      TYPE(simpar_type), POINTER                 :: simpar => NULL()
      TYPE(average_quantities_type), POINTER     :: averages => NULL()
      TYPE(thermal_regions_type), POINTER        :: thermal_regions => NULL()
   END TYPE md_environment_type

   ! *** Public subroutines and data types ***
   PUBLIC :: md_environment_type, set_md_env, get_md_env, md_env_create, &
             md_env_release, need_per_atom_wiener_process

   ! *** Global parameters ***
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'md_environment_types'

CONTAINS

! **************************************************************************************************
!> \brief Creates MD environment
!>      Purpose: Initialise the integrator environment.
!>      retain the para_env for this environment (should be used for parallel
!>      communications)
!> \param md_env the force environment to retain
!> \param md_section ...
!> \param para_env ...
!> \param force_env ...
! **************************************************************************************************
   SUBROUTINE md_env_create(md_env, md_section, para_env, force_env)
      TYPE(md_environment_type), INTENT(OUT)             :: md_env
      TYPE(section_vals_type), POINTER                   :: md_section
      TYPE(mp_para_env_type), POINTER                    :: para_env
      TYPE(force_env_type), POINTER                      :: force_env

      TYPE(section_vals_type), POINTER                   :: averages_section

      md_env%para_env => para_env
      CALL md_env%para_env%retain()
      ALLOCATE (md_env%itimes)
      ALLOCATE (md_env%constant)
      ALLOCATE (md_env%used_time)
      ALLOCATE (md_env%t)
      md_env%itimes = -1
      md_env%constant = 0.0_dp
      md_env%used_time = 0.0_dp
      md_env%t = 0.0_dp
      md_env%init = .TRUE.
      md_env%first_time = .TRUE.
      md_env%ehrenfest_md = .FALSE.
      averages_section => section_vals_get_subs_vals(md_section, "AVERAGES")
      CALL create_averages(md_env%averages, averages_section, force_env=force_env)

   END SUBROUTINE md_env_create

! **************************************************************************************************
!> \brief releases the given md env
!> \param md_env the md environment to release
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE md_env_release(md_env)
      TYPE(md_environment_type), INTENT(INOUT)           :: md_env

      CALL fe_env_release(md_env%fe_env)
      CALL mp_para_env_release(md_env%para_env)
      DEALLOCATE (md_env%itimes)
      DEALLOCATE (md_env%constant)
      DEALLOCATE (md_env%used_time)
      DEALLOCATE (md_env%t)

      NULLIFY (md_env%cell)
      NULLIFY (md_env%simpar)
      CALL release_barostat_type(md_env%barostat)
      IF (ASSOCIATED(md_env%thermostats)) THEN
         CALL release_thermostats(md_env%thermostats)
         DEALLOCATE (md_env%thermostats)
      END IF
      IF (ASSOCIATED(md_env%reftraj)) THEN
         CALL release_reftraj(md_env%reftraj)
         DEALLOCATE (md_env%reftraj)
      END IF
      IF (ASSOCIATED(md_env%md_ener)) THEN
         CALL release_md_ener(md_env%md_ener)
         DEALLOCATE (md_env%md_ener)
      END IF
      CALL force_env_release(md_env%force_env)
      CALL release_averages(md_env%averages)
      IF (ASSOCIATED(md_env%thermal_regions)) THEN
         CALL release_thermal_regions(md_env%thermal_regions)
         DEALLOCATE (md_env%thermal_regions)
      END IF

   END SUBROUTINE md_env_release

! **************************************************************************************************
!> \brief get components of MD environment type
!> \param md_env the force environment to retain
!> \param itimes ...
!> \param constant ...
!> \param used_time ...
!> \param cell ...
!> \param simpar ...
!> \param npt ...
!> \param force_env ...
!> \param para_env ...
!> \param reftraj ...
!> \param t ...
!> \param init ...
!> \param first_time ...
!> \param fe_env ...
!> \param thermostats ...
!> \param barostat ...
!> \param thermostat_coeff ...
!> \param thermostat_part ...
!> \param thermostat_shell ...
!> \param thermostat_baro ...
!> \param thermostat_fast ...
!> \param thermostat_slow ...
!> \param md_ener ...
!> \param averages ...
!> \param thermal_regions ...
!> \param ehrenfest_md ...
! **************************************************************************************************
   SUBROUTINE get_md_env(md_env, itimes, constant, used_time, cell, simpar, npt, &
                         force_env, para_env, reftraj, t, init, first_time, fe_env, thermostats, barostat, &
                         thermostat_coeff, thermostat_part, thermostat_shell, thermostat_baro, &
                         thermostat_fast, thermostat_slow, md_ener, averages, &
                         thermal_regions, ehrenfest_md)

      TYPE(md_environment_type), INTENT(IN)              :: md_env
      INTEGER, OPTIONAL, POINTER                         :: itimes
      REAL(KIND=dp), OPTIONAL, POINTER                   :: constant, used_time
      TYPE(cell_type), OPTIONAL, POINTER                 :: cell
      TYPE(simpar_type), OPTIONAL, POINTER               :: simpar
      TYPE(npt_info_type), OPTIONAL, POINTER             :: npt(:, :)
      TYPE(force_env_type), OPTIONAL, POINTER            :: force_env
      TYPE(mp_para_env_type), OPTIONAL, POINTER          :: para_env
      TYPE(reftraj_type), OPTIONAL, POINTER              :: reftraj
      REAL(KIND=dp), OPTIONAL, POINTER                   :: t
      LOGICAL, OPTIONAL                                  :: init, first_time
      TYPE(free_energy_type), OPTIONAL, POINTER          :: fe_env
      TYPE(thermostats_type), OPTIONAL, POINTER          :: thermostats
      TYPE(barostat_type), OPTIONAL, POINTER             :: barostat
      TYPE(thermostat_type), OPTIONAL, POINTER           :: thermostat_coeff, thermostat_part, &
                                                            thermostat_shell, thermostat_baro, &
                                                            thermostat_fast, thermostat_slow
      TYPE(md_ener_type), OPTIONAL, POINTER              :: md_ener
      TYPE(average_quantities_type), OPTIONAL, POINTER   :: averages
      TYPE(thermal_regions_type), OPTIONAL, POINTER      :: thermal_regions
      LOGICAL, OPTIONAL                                  :: ehrenfest_md

      IF (PRESENT(itimes)) itimes => md_env%itimes
      IF (PRESENT(fe_env)) fe_env => md_env%fe_env
      IF (PRESENT(constant)) constant => md_env%constant
      IF (PRESENT(used_time)) used_time => md_env%used_time
      IF (PRESENT(t)) t => md_env%t
      IF (PRESENT(cell)) cell => md_env%cell
      IF (PRESENT(simpar)) simpar => md_env%simpar
      IF (PRESENT(thermostats)) thermostats => md_env%thermostats
      IF (PRESENT(barostat)) barostat => md_env%barostat
      IF (PRESENT(thermostat_part) .OR. PRESENT(thermostat_coeff) .OR. &
          PRESENT(thermostat_baro) .OR. PRESENT(thermostat_shell) .OR. &
          PRESENT(thermostat_fast) .OR. PRESENT(thermostat_slow)) THEN
         IF (ASSOCIATED(md_env%thermostats)) THEN
            IF (PRESENT(thermostat_part)) THEN
               thermostat_part => md_env%thermostats%thermostat_part
            END IF
            IF (PRESENT(thermostat_coeff)) THEN
               thermostat_coeff => md_env%thermostats%thermostat_coef
            END IF
            IF (PRESENT(thermostat_shell)) THEN
               thermostat_shell => md_env%thermostats%thermostat_shell
            END IF
            IF (PRESENT(thermostat_fast)) THEN
               thermostat_fast => md_env%thermostats%thermostat_fast
            END IF
            IF (PRESENT(thermostat_slow)) THEN
               thermostat_slow => md_env%thermostats%thermostat_slow
            END IF
            IF (PRESENT(thermostat_baro)) THEN
               thermostat_baro => md_env%thermostats%thermostat_baro
            END IF
         END IF
      END IF
      IF (PRESENT(npt)) THEN
         IF (ASSOCIATED(md_env%barostat)) THEN
            npt => md_env%barostat%npt
         END IF
      END IF
      IF (PRESENT(averages)) averages => md_env%averages
      IF (PRESENT(force_env)) force_env => md_env%force_env
      IF (PRESENT(para_env)) para_env => md_env%para_env
      IF (PRESENT(reftraj)) reftraj => md_env%reftraj
      IF (PRESENT(md_ener)) md_ener => md_env%md_ener
      IF (PRESENT(init)) init = md_env%init
      IF (PRESENT(first_time)) first_time = md_env%first_time
      IF (PRESENT(ehrenfest_md)) ehrenfest_md = md_env%ehrenfest_md
      IF (PRESENT(thermal_regions)) thermal_regions => md_env%thermal_regions

   END SUBROUTINE get_md_env

! **************************************************************************************************
!> \brief Set the integrator environment to the correct program.
!> \param md_env the force environment to retain
!> \param itimes ...
!> \param constant ...
!> \param cell ...
!> \param simpar ...
!> \param fe_env ...
!> \param force_env ...
!> \param para_env ...
!> \param init ...
!> \param first_time ...
!> \param thermostats ...
!> \param barostat ...
!> \param reftraj ...
!> \param md_ener ...
!> \param averages ...
!> \param thermal_regions ...
!> \param ehrenfest_md ...
! **************************************************************************************************
   SUBROUTINE set_md_env(md_env, itimes, constant, cell, simpar, fe_env, force_env, &
                         para_env, init, first_time, thermostats, barostat, reftraj, md_ener, averages, &
                         thermal_regions, ehrenfest_md)

      TYPE(md_environment_type), INTENT(INOUT)           :: md_env
      INTEGER, OPTIONAL, POINTER                         :: itimes
      REAL(KIND=dp), OPTIONAL, POINTER                   :: constant
      TYPE(cell_type), OPTIONAL, POINTER                 :: cell
      TYPE(simpar_type), OPTIONAL, POINTER               :: simpar
      TYPE(free_energy_type), OPTIONAL, POINTER          :: fe_env
      TYPE(force_env_type), OPTIONAL, POINTER            :: force_env
      TYPE(mp_para_env_type), OPTIONAL, POINTER          :: para_env
      LOGICAL, OPTIONAL                                  :: init, first_time
      TYPE(thermostats_type), OPTIONAL, POINTER          :: thermostats
      TYPE(barostat_type), OPTIONAL, POINTER             :: barostat
      TYPE(reftraj_type), OPTIONAL, POINTER              :: reftraj
      TYPE(md_ener_type), OPTIONAL, POINTER              :: md_ener
      TYPE(average_quantities_type), OPTIONAL, POINTER   :: averages
      TYPE(thermal_regions_type), OPTIONAL, POINTER      :: thermal_regions
      LOGICAL, OPTIONAL                                  :: ehrenfest_md

      IF (PRESENT(init)) md_env%init = init
      IF (PRESENT(first_time)) md_env%first_time = first_time
      IF (PRESENT(ehrenfest_md)) md_env%ehrenfest_md = ehrenfest_md
      IF (PRESENT(cell)) md_env%cell => cell
      IF (PRESENT(barostat)) THEN
         IF (ASSOCIATED(md_env%barostat)) THEN
         IF (.NOT. ASSOCIATED(md_env%barostat, barostat)) THEN
            CALL release_barostat_type(md_env%barostat)
         END IF
         END IF
         md_env%barostat => barostat
      END IF
      IF (PRESENT(thermostats)) THEN
         IF (ASSOCIATED(md_env%thermostats)) THEN
         IF (.NOT. ASSOCIATED(md_env%thermostats, thermostats)) THEN
            CALL release_thermostats(md_env%thermostats)
            DEALLOCATE (md_env%thermostats)
         END IF
         END IF
         md_env%thermostats => thermostats
      END IF
      IF (PRESENT(simpar)) md_env%simpar => simpar
      IF (PRESENT(itimes)) md_env%itimes => itimes
      IF (PRESENT(fe_env)) md_env%fe_env => fe_env
      IF (PRESENT(constant)) md_env%constant => constant
      IF (PRESENT(para_env)) md_env%para_env => para_env
      IF (PRESENT(force_env)) THEN
         IF (ASSOCIATED(force_env)) THEN
            CALL force_env_retain(force_env)
         END IF
         IF (ASSOCIATED(md_env%force_env)) THEN
            CALL force_env_release(md_env%force_env)
         END IF
         md_env%force_env => force_env
      END IF
      IF (PRESENT(reftraj)) THEN
         IF (ASSOCIATED(md_env%reftraj)) THEN
         IF (.NOT. ASSOCIATED(md_env%reftraj, reftraj)) THEN
            CALL release_reftraj(md_env%reftraj)
            DEALLOCATE (md_env%reftraj)
         END IF
         END IF
         md_env%reftraj => reftraj
      END IF
      IF (PRESENT(md_ener)) THEN
         IF (ASSOCIATED(md_env%md_ener)) THEN
            IF (.NOT. ASSOCIATED(md_env%md_ener, md_ener)) THEN
               CALL release_md_ener(md_env%md_ener)
               DEALLOCATE (md_env%md_ener)
            END IF
         END IF
         md_env%md_ener => md_ener
      END IF
      IF (PRESENT(averages)) THEN
         CALL release_averages(md_env%averages)
         CALL retain_averages(averages)
         md_env%averages => averages
      END IF
      IF (PRESENT(thermal_regions)) THEN
         IF (ASSOCIATED(md_env%thermal_regions)) THEN
            IF (.NOT. ASSOCIATED(md_env%thermal_regions, thermal_regions)) THEN
               CALL release_thermal_regions(md_env%thermal_regions)
               DEALLOCATE (md_env%thermal_regions)
            END IF
         END IF
         md_env%thermal_regions => thermal_regions
      END IF

   END SUBROUTINE set_md_env

! **************************************************************************************************
!> \brief ...
!> \param md_env ...
!> \return ...
!> \par History
!>      02.2012 created [noamb]
!> \author Noam Bernstein
! **************************************************************************************************
   PURE FUNCTION need_per_atom_wiener_process(md_env)
      TYPE(md_environment_type), INTENT(IN)              :: md_env
      LOGICAL                                            :: need_per_atom_wiener_process

! return value
! check for Langevin ensemble

      need_per_atom_wiener_process = (md_env%simpar%ensemble == langevin_ensemble)
      IF (need_per_atom_wiener_process) RETURN

      ! check for adaptive-Langevin thermostat
      IF (.NOT. ASSOCIATED(md_env%thermostats)) RETURN
      IF (.NOT. ASSOCIATED(md_env%thermostats%thermostat_part)) RETURN
      need_per_atom_wiener_process = (md_env%thermostats%thermostat_part%type_of_thermostat == do_thermo_al)

   END FUNCTION need_per_atom_wiener_process

END MODULE md_environment_types
