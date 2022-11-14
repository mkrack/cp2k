#!-------------------------------------------------------------------------------------------------!
#!   CP2K: A general program to perform molecular dynamics simulations                             !
#!   Copyright 2000-2022 CP2K developers group <https://cp2k.org>                                  !
#!                                                                                                 !
#!   SPDX-License-Identifier: GPL-2.0-or-later                                                     !
#!-------------------------------------------------------------------------------------------------!

# Copyright (c) 2022- ETH Zurich
#
# authors : Mathieu Taillefumier

include(FindPackageHandleStandardArgs)
include(cp2k_utils)

find_package(PkgConfig)
cp2k_set_default_paths(SUPERLU "SuperLU")
pkg_search_module(CP2K_SUPERLU IMPORTED_TARGET GLOBAL "superlu superlu_dist")

if(NOT CP2K_SUPERLU_FOUND)
  cp2k_find_libraries(SUPERLU "superlu;superlu_dist")
endif()

if(NOT CP2K_SUPERLU_INCLUDE_DIRS)
  cp2k_include_dirs(SUPERLU
                    "supermatrix.h;SuperLU/supermatrix.h;superlu/supermatrix.h")
endif()

find_package_handle_standard_args(SuperLU DEFAULT_MSG CP2K_SUPERLU_INCLUDE_DIRS
                                  CP2K_SUPERLU_LINK_LIBRARIES)

if(CP2K_SUPERLU_FOUND AND NOT TARGET CP2K_superlu::superlu)
  add_library(CP2K_superlu::superlu INTERFACE IMPORTED)
  set_target_properties(
    CP2K_superlu::superlu
    PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${CP2K_SUPERLU_INCLUDE_DIRS}"
               INTERFACE_LINK_LIBRARIES "${CP2K_SUPERLU_LINK_LIBRARIES}")
endif()