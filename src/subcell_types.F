!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief subcell types and allocation routines
!> \par History
!>      - Separated from qs_neighbor_lists (25.07.2010,jhu)
!> \author Matthias Krack
! **************************************************************************************************
MODULE subcell_types

   USE cell_types,                      ONLY: cell_type,&
                                              real_to_scaled,&
                                              scaled_to_real
   USE kinds,                           ONLY: dp
   USE util,                            ONLY: sort
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! **************************************************************************************************
   TYPE subcell_type
      INTEGER                        :: natom = -1
      REAL(KIND=dp), DIMENSION(3)    :: s_max = -1.0_dp, s_min = -1.0_dp
      INTEGER, DIMENSION(:), POINTER :: atom_list => NULL()
      REAL(KIND=dp), DIMENSION(3, 8)  :: corners = -1.0_dp
   END TYPE subcell_type

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'subcell_types'

   PUBLIC :: subcell_type, allocate_subcell, deallocate_subcell
   PUBLIC :: reorder_atoms_subcell, give_ijk_subcell

! **************************************************************************************************

CONTAINS

! **************************************************************************************************
!> \brief Allocate and initialize a subcell grid structure for the atomic neighbor search.
!> \param subcell ...
!> \param nsubcell ...
!> \param maxatom ...
!> \param cell ...
!> \date    12.06.2003
!> \author MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE allocate_subcell(subcell, nsubcell, maxatom, cell)

      TYPE(subcell_type), DIMENSION(:, :, :), POINTER    :: subcell
      INTEGER, DIMENSION(3), INTENT(IN)                  :: nsubcell
      INTEGER, INTENT(IN), OPTIONAL                      :: maxatom
      TYPE(cell_type), OPTIONAL, POINTER                 :: cell

      INTEGER                                            :: i, j, k, na, nb, nc
      REAL(dp)                                           :: a_max, a_min, b_max, b_min, c_max, &
                                                            c_min, delta_a, delta_b, delta_c

      na = nsubcell(1)
      nb = nsubcell(2)
      nc = nsubcell(3)

      ALLOCATE (subcell(na, nb, nc))

      delta_a = 1.0_dp/REAL(na, dp)
      delta_b = 1.0_dp/REAL(nb, dp)
      delta_c = 1.0_dp/REAL(nc, dp)

      c_min = -0.5_dp

      DO k = 1, nc
         c_max = c_min + delta_c
         b_min = -0.5_dp
         DO j = 1, nb
            b_max = b_min + delta_b
            a_min = -0.5_dp
            DO i = 1, na
               a_max = a_min + delta_a
               subcell(i, j, k)%s_min(1) = a_min
               subcell(i, j, k)%s_min(2) = b_min
               subcell(i, j, k)%s_min(3) = c_min
               subcell(i, j, k)%s_max(1) = a_max
               subcell(i, j, k)%s_max(2) = b_max
               subcell(i, j, k)%s_max(3) = c_max
               subcell(i, j, k)%natom = 0
               IF (PRESENT(cell)) THEN
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 1), (/a_min, b_min, c_min/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 2), (/a_max, b_min, c_min/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 3), (/a_min, b_max, c_min/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 4), (/a_max, b_max, c_min/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 5), (/a_min, b_min, c_max/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 6), (/a_max, b_min, c_max/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 7), (/a_min, b_max, c_max/), cell)
                  CALL scaled_to_real(subcell(i, j, k)%corners(:, 8), (/a_max, b_max, c_max/), cell)
               END IF
               IF (PRESENT(maxatom)) THEN
                  ALLOCATE (subcell(i, j, k)%atom_list(maxatom))
               END IF
               a_min = a_max
            END DO
            b_min = b_max
         END DO
         c_min = c_max
      END DO

   END SUBROUTINE allocate_subcell

! **************************************************************************************************
!> \brief   Deallocate a subcell grid structure.
!> \param subcell ...
!> \date    16.06.2003
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE deallocate_subcell(subcell)

      TYPE(subcell_type), DIMENSION(:, :, :), POINTER    :: subcell

      INTEGER                                            :: i, j, k

      IF (ASSOCIATED(subcell)) THEN

         DO k = 1, SIZE(subcell, 3)
            DO j = 1, SIZE(subcell, 2)
               DO i = 1, SIZE(subcell, 1)
                  DEALLOCATE (subcell(i, j, k)%atom_list)
               END DO
            END DO
         END DO

         DEALLOCATE (subcell)
      ELSE
         CPABORT("")
      END IF

   END SUBROUTINE deallocate_subcell

! **************************************************************************************************
!> \brief ...
!> \param atom_list ...
!> \param kind_of ...
!> \param work ...
!> \par History
!>      08.2006 created [tlaino]
!> \author Teodoro Laino
! **************************************************************************************************
   SUBROUTINE reorder_atoms_subcell(atom_list, kind_of, work)
      ! work needs to be dimensioned 3xSIZE(atom_list)
      INTEGER, DIMENSION(:), POINTER                     :: atom_list
      INTEGER, DIMENSION(:), INTENT(IN)                  :: kind_of
      INTEGER, DIMENSION(:)                              :: work

      INTEGER                                            :: i, i0, i1, i2, j0, j1, j2

      i0 = 1
      j0 = SIZE(atom_list)
      i1 = j0 + 1
      j1 = 2*j0
      i2 = j1 + 1
      j2 = 3*j0
      ! Sort kind
      DO i = 1, SIZE(atom_list)
         work(i0 + i - 1) = kind_of(atom_list(i))
      END DO
      CALL sort(work(i0:j0), SIZE(atom_list), work(i1:j1))
      work(i2:j2) = atom_list
      DO i = 1, SIZE(atom_list)
         atom_list(i) = work(i2 + work(i1 + i - 1) - 1)
      END DO
   END SUBROUTINE reorder_atoms_subcell

! **************************************************************************************************
!> \brief ...
!> \param r ...
!> \param i ...
!> \param j ...
!> \param k ...
!> \param cell ...
!> \param nsubcell ...
!> \par History
!>      08.2006 created [tlaino]
!> \author Teodoro Laino
! **************************************************************************************************
   SUBROUTINE give_ijk_subcell(r, i, j, k, cell, nsubcell)
      REAL(KIND=dp)                                      :: r(3)
      INTEGER, INTENT(OUT)                               :: i, j, k
      TYPE(cell_type), POINTER                           :: cell
      INTEGER, DIMENSION(3), INTENT(IN)                  :: nsubcell

      REAL(KIND=dp)                                      :: r_pbc(3), s(3), s_pbc(3)

      r_pbc = r
      CALL real_to_scaled(s_pbc, r_pbc, cell)
      s(:) = s_pbc + 0.5_dp
      i = INT(s(1)*REAL(nsubcell(1), KIND=dp)) + 1
      j = INT(s(2)*REAL(nsubcell(2), KIND=dp)) + 1
      k = INT(s(3)*REAL(nsubcell(3), KIND=dp)) + 1
      i = MIN(MAX(i, 1), nsubcell(1))
      j = MIN(MAX(j, 1), nsubcell(2))
      k = MIN(MAX(k, 1), nsubcell(3))

   END SUBROUTINE give_ijk_subcell

END MODULE subcell_types
