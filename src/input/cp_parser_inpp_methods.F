!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief a module to allow simple internal preprocessing in input files.
!> \par History
!>      - standalone proof-of-concept implementation (20.02.2008,AK)
!>      - integration into cp2k (22.02.2008,tlaino)
!>      - variables added (23.02.2008,AK)
!>      - @IF/@ENDIF added (25.02.2008,AK)
!>      - @PRINT and debug ifdefs added (26.02.2008,AK)
!> \author Axel Kohlmeyer [AK] - CMM/UPenn Philadelphia
!> \date 20.02.2008
! **************************************************************************************************
MODULE cp_parser_inpp_methods
   USE cp_files, ONLY: close_file, &
                       open_file, file_exists
   USE cp_log_handling, ONLY: cp_logger_get_default_io_unit
   USE cp_parser_inpp_types, ONLY: inpp_type
   USE kinds, ONLY: default_path_length, &
                    default_string_length
   USE memory_utilities, ONLY: reallocate
   USE string_utilities, ONLY: is_whitespace, &
                               uppercase
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_parser_inpp_methods'
   LOGICAL, PARAMETER, PRIVATE          :: debug_this_module = .FALSE.
   INTEGER, PARAMETER, PRIVATE          :: max_message_length = 400

   PUBLIC  :: inpp_process_directive, inpp_end_include, inpp_expand_variables
   PRIVATE :: inpp_find_variable, inpp_list_variables

CONTAINS

! **************************************************************************************************
!> \brief Validates whether the given string is a valid preprocessor variable name
!> \param str The input string (must be already trimmed if necessary)
!> \return .TRUE. if it is a valid variable name, .FALSE. otherwise
! **************************************************************************************************
   LOGICAL PURE FUNCTION is_valid_varname(str)
      CHARACTER(LEN=*), INTENT(IN) :: str
      CHARACTER(LEN=*), PARAMETER  :: alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
      CHARACTER(LEN=*), PARAMETER  :: alphanum = alpha//"0123456789"
      INTEGER                      :: idx

      is_valid_varname = .FALSE.

      IF (LEN(str) == 0) &
         RETURN

      IF (INDEX(alpha, str(1:1)) == 0) &
         RETURN

      DO idx = 2, LEN(str)
         IF (INDEX(alphanum, str(idx:idx)) == 0) &
            RETURN
      END DO

      is_valid_varname = .TRUE.
   END FUNCTION is_valid_varname
! **************************************************************************************************
!> \brief process internal preprocessor directives like @INCLUDE, @SET, @IF/@ENDIF
!> \param inpp ...
!> \param input_line ...
!> \param input_file_name ...
!> \param input_line_number ...
!> \param input_unit ...
!> \par History
!>      - standalone proof-of-concept implementation (20.02.2008,AK)
!>      - integration into cp2k (22.02.2008,tlaino)
!>      - variables added (23.02.2008,AK)
!>      - @IF/@ENDIF added (25.02.2008,AK)
!> \author AK
! **************************************************************************************************
   SUBROUTINE inpp_process_directive(inpp, input_line, input_file_name, input_line_number, &
                                     input_unit)
      TYPE(inpp_type), POINTER                           :: inpp
      CHARACTER(LEN=*), INTENT(INOUT)                    :: input_line, input_file_name
      INTEGER, INTENT(INOUT)                             :: input_line_number, input_unit

      CHARACTER(LEN=default_path_length)                 :: cond1, cond2, filename, mytag, value, &
                                                            varname
      CHARACTER(LEN=max_message_length)                  :: message
      INTEGER                                            :: i, indf, indi, istat, output_unit, pos1, &
                                                            pos2, unit
      LOGICAL                                            :: check

      output_unit = cp_logger_get_default_io_unit()

      CPASSERT(ASSOCIATED(inpp))

      ! Find location of directive in line and check whether it is commented out
      indi = INDEX(input_line, "@")
      pos1 = INDEX(input_line, "!")
      pos2 = INDEX(input_line, "#")
      IF (((pos1 > 0) .AND. (pos1 < indi)) .OR. ((pos2 > 0) .AND. (pos2 < indi))) THEN
         ! Nothing to do
         RETURN
      END IF

      ! Get the start of the instruction and find "@KEYWORD" (or "@")
      indf = indi
      DO WHILE (.NOT. is_whitespace(input_line(indf:indf)))
         indf = indf + 1
      END DO
      mytag = input_line(indi:indf - 1)
      CALL uppercase(mytag)

      SELECT CASE (mytag)

      CASE ("@INCLUDE")
         ! Get the file name, allow for " or ' or nothing
         filename = TRIM(input_line(indf:))
         IF (LEN_TRIM(filename) == 0) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               "No filename argument found for "//TRIM(mytag)// &
               " directive in file <"//TRIM(input_file_name)// &
               ">  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF
         indi = 1
         DO WHILE (is_whitespace(filename(indi:indi)))
            indi = indi + 1
         END DO
         filename = TRIM(filename(indi:))

         ! Handle quoting of the filename
         pos1 = INDEX(filename, '"')
         pos2 = INDEX(filename(pos1 + 1:), '"')
         IF ((pos1 /= 0) .AND. (pos2 /= 0)) THEN
            filename = filename(pos1 + 1:pos1 + pos2 - 1)
         ELSE
            pos1 = INDEX(filename, "'")
            pos2 = INDEX(filename(pos1 + 1:), "'")
            IF ((pos1 /= 0) .AND. (pos2 /= 0)) THEN
               filename = filename(pos1 + 1:pos1 + pos2 - 1)
            ELSE
               ! Check quoting of the included file name
               pos2 = INDEX(filename, '"')
               IF ((pos1 /= 0) .OR. (pos2 /= 0)) THEN
                  WRITE (UNIT=message, FMT="(A,I0)") &
                     "Incorrect quoting of the included filename in file <", &
                     TRIM(input_file_name)//">  Line:", input_line_number
                  CPABORT(TRIM(message))
               END IF
            END IF
         END IF

         ! Let's check that files already opened won't be again opened
         DO i = 1, inpp%io_stack_level
            check = TRIM(filename) /= TRIM(inpp%io_stack_filename(i))
            CPASSERT(check)
         END DO

         CALL open_file(file_name=TRIM(filename), &
                        file_status="OLD", &
                        file_form="FORMATTED", &
                        file_action="READ", &
                        unit_number=unit)

         ! Make room, save status and position the parser at the beginning of new file.
         inpp%io_stack_level = inpp%io_stack_level + 1
         CALL reallocate(inpp%io_stack_channel, 1, inpp%io_stack_level)
         CALL reallocate(inpp%io_stack_lineno, 1, inpp%io_stack_level)
         CALL reallocate(inpp%io_stack_filename, 1, inpp%io_stack_level)

         inpp%io_stack_channel(inpp%io_stack_level) = input_unit
         inpp%io_stack_lineno(inpp%io_stack_level) = input_line_number
         inpp%io_stack_filename(inpp%io_stack_level) = input_file_name

         input_file_name = TRIM(filename)
         input_line_number = 0
         input_unit = unit

      CASE ("@FFTYPE", "@XCTYPE")
         ! Include a &XC section from the data/xc_section directory or include
         ! a &FORCEFIELD section from the data/forcefield_section directory
         ! Get the filename, allow for " or ' or nothing
         filename = TRIM(input_line(indf:))
         IF (LEN_TRIM(filename) == 0) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               "No filename argument found for "//TRIM(mytag)// &
               " directive in file <"//TRIM(input_file_name)// &
               ">  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF
         indi = 1
         DO WHILE (is_whitespace(filename(indi:indi)))
            indi = indi + 1
         END DO
         filename = TRIM(filename(indi:))

         ! Handle quoting of the filename
         pos1 = INDEX(filename, '"')
         pos2 = INDEX(filename(pos1 + 1:), '"')
         IF ((pos1 /= 0) .AND. (pos2 /= 0)) THEN
            filename = filename(pos1 + 1:pos1 + pos2 - 1)
         ELSE
            pos1 = INDEX(filename, "'")
            pos2 = INDEX(filename(pos1 + 1:), "'")
            IF ((pos1 /= 0) .AND. (pos2 /= 0)) THEN
               filename = filename(pos1 + 1:pos1 + pos2 - 1)
            ELSE
               ! Incorrect quotes (only one of ' or ").
               pos2 = INDEX(filename, '"')
               IF ((pos1 /= 0) .OR. (pos2 /= 0)) THEN
                  WRITE (UNIT=message, FMT="(A,I0)") &
                     "Incorrect quoting of the filename argument in file <", &
                     TRIM(input_file_name)//">  Line:", input_line_number
                  CPABORT(TRIM(message))
               END IF
            END IF
         END IF

         ! Add file extension ".sec"
         filename = TRIM(filename)//".sec"
         ! Check for file
         IF (.NOT. file_exists(TRIM(filename))) THEN
            IF (filename(1:1) == "/") THEN
               ! this is an absolute path filename, don't change
            ELSE
               SELECT CASE (mytag)
               CASE ("@FFTYPE")
                  filename = "forcefield_section/"//TRIM(filename)
               CASE ("@XCTYPE")
                  filename = "xc_section/"//TRIM(filename)
               END SELECT
            END IF
         END IF
         IF (.NOT. file_exists(TRIM(filename))) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               TRIM(mytag)//": Could not find the file <"// &
               TRIM(filename)//"> with the input section given in the file <"// &
               TRIM(input_file_name)//">  Line: ", input_line_number
            CPABORT(TRIM(message))
         END IF

         ! Let's check that files already opened won't be again opened
         DO i = 1, inpp%io_stack_level
            check = TRIM(filename) /= TRIM(inpp%io_stack_filename(i))
            CPASSERT(check)
         END DO

         ! This stops on error so we can always assume success
         CALL open_file(file_name=TRIM(filename), &
                        file_status="OLD", &
                        file_form="FORMATTED", &
                        file_action="READ", &
                        unit_number=unit)

         ! make room, save status and position the parser at the beginning of new file.
         inpp%io_stack_level = inpp%io_stack_level + 1
         CALL reallocate(inpp%io_stack_channel, 1, inpp%io_stack_level)
         CALL reallocate(inpp%io_stack_lineno, 1, inpp%io_stack_level)
         CALL reallocate(inpp%io_stack_filename, 1, inpp%io_stack_level)

         inpp%io_stack_channel(inpp%io_stack_level) = input_unit
         inpp%io_stack_lineno(inpp%io_stack_level) = input_line_number
         inpp%io_stack_filename(inpp%io_stack_level) = input_file_name

         input_file_name = TRIM(filename)
         input_line_number = 0
         input_unit = unit

      CASE ("@SET")
         ! Split directive into variable name and value data.
         varname = TRIM(input_line(indf:))
         IF (LEN_TRIM(varname) == 0) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               "No variable name found for "//TRIM(mytag)//" directive in file <"// &
               TRIM(input_file_name)//">  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         indi = 1
         DO WHILE (is_whitespace(varname(indi:indi)))
            indi = indi + 1
         END DO
         indf = indi
         DO WHILE (.NOT. is_whitespace(varname(indf:indf)))
            indf = indf + 1
         END DO
         value = TRIM(varname(indf:))
         varname = TRIM(varname(indi:indf - 1))

         IF (.NOT. is_valid_varname(TRIM(varname))) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               "Invalid variable name for "//TRIM(mytag)//" directive in file <"// &
               TRIM(input_file_name)//">  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         indi = 1
         DO WHILE (is_whitespace(value(indi:indi)))
            indi = indi + 1
         END DO
         value = TRIM(value(indi:))

         IF (LEN_TRIM(value) == 0) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               "Incomplete "//TRIM(mytag)//" directive: "// &
               "No value found for variable <"//TRIM(varname)//"> in file <"// &
               TRIM(input_file_name)//">  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         ! sort into table of variables.
         indi = inpp_find_variable(inpp, varname)
         IF (indi == 0) THEN
            ! create new variable
            inpp%num_variables = inpp%num_variables + 1
            CALL reallocate(inpp%variable_name, 1, inpp%num_variables)
            CALL reallocate(inpp%variable_value, 1, inpp%num_variables)
            inpp%variable_name(inpp%num_variables) = varname
            inpp%variable_value(inpp%num_variables) = value
            IF (debug_this_module .AND. output_unit > 0) THEN
               WRITE (UNIT=message, FMT="(3A,I6,4A)") "INPP_@SET: in file: ", &
                  TRIM(input_file_name), "  Line:", input_line_number, &
                  " Set new variable ", TRIM(varname), " to value: ", TRIM(value)
               WRITE (output_unit, *) TRIM(message)
            END IF
         ELSE
            ! reassign variable
            IF (debug_this_module .AND. output_unit > 0) THEN
               WRITE (UNIT=message, FMT="(3A,I6,6A)") "INPP_@SET: in file: ", &
                  TRIM(input_file_name), "  Line:", input_line_number, &
                  " Change variable ", TRIM(varname), " from value: ", &
                  TRIM(inpp%variable_value(indi)), " to value: ", TRIM(value)
               WRITE (output_unit, *) TRIM(message)
            END IF
            inpp%variable_value(indi) = value
         END IF

         IF (debug_this_module) CALL inpp_list_variables(inpp, 6)

      CASE ("@IF")
         ! detect IF expression.
         ! we recognize lexical equality or inequality, and presence of
         ! a string (true) vs. blank (false). in case the expression resolves
         ! to "false" we read lines here until we reach an @ENDIF or EOF.
         indi = indf
         pos1 = INDEX(input_line, "==")
         pos2 = INDEX(input_line, "/=")
         ! shave off leading whitespace
         DO WHILE (is_whitespace(input_line(indi:indi)))
            indi = indi + 1
            IF (indi > LEN_TRIM(input_line)) EXIT
         END DO
         check = .FALSE.
         IF (pos1 > 0) THEN
            cond1 = input_line(indi:pos1 - 1)
            cond2 = input_line(pos1 + 2:)
            check = .TRUE.
            IF ((pos2 > 0) .OR. (INDEX(cond2, "==") > 0)) THEN
               WRITE (UNIT=message, FMT="(A,I0)") &
                  "Incorrect "//TRIM(mytag)//" directive found in file <", &
                  TRIM(input_file_name)//">  Line:", input_line_number
               CPABORT(TRIM(message))
            END IF
         ELSE IF (pos2 > 0) THEN
            cond1 = input_line(indi:pos2 - 1)
            cond2 = input_line(pos2 + 2:)
            check = .FALSE.
            IF ((pos1 > 0) .OR. (INDEX(cond2, "/=") > 0)) THEN
               WRITE (UNIT=message, FMT="(A,I0)") &
                  "Incorrect "//TRIM(mytag)//" directive found in file <", &
                  TRIM(input_file_name)//">  Line:", input_line_number
               CPABORT(TRIM(message))
            END IF
         ELSE
            IF (LEN_TRIM(input_line(indi:)) > 0) THEN
               IF (TRIM(input_line(indi:)) == '0') THEN
                  cond1 = 'XXX'
                  cond2 = 'XXX'
                  check = .FALSE.
               ELSE
                  cond1 = 'XXX'
                  cond2 = 'XXX'
                  check = .TRUE.
               END IF
            ELSE
               cond1 = 'XXX'
               cond2 = 'XXX'
               check = .FALSE.
            END IF
         END IF

         ! Get rid of possible parentheses
         IF (INDEX(cond1, "(") /= 0) cond1 = cond1(INDEX(cond1, "(") + 1:)
         IF (INDEX(cond2, ")") /= 0) cond2 = cond2(1:INDEX(cond2, ")") - 1)

         ! Shave off leading whitespace from cond1
         indi = 1
         DO WHILE (is_whitespace(cond1(indi:indi)))
            indi = indi + 1
         END DO
         cond1 = cond1(indi:)

         ! Shave off leading whitespace from cond2
         indi = 1
         DO WHILE (is_whitespace(cond2(indi:indi)))
            indi = indi + 1
         END DO
         cond2 = cond2(indi:)

         IF (LEN_TRIM(cond2) == 0) THEN
            WRITE (UNIT=message, FMT="(3A,I6)") &
               "INPP_@IF: Incorrect @IF directive in file: ", &
               TRIM(input_file_name), "  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         IF ((TRIM(cond1) == TRIM(cond2)) .EQV. check) THEN
            IF (debug_this_module .AND. output_unit > 0) THEN
               WRITE (UNIT=message, FMT="(3A,I6,A)") "INPP_@IF: in file: ", &
                  TRIM(input_file_name), "  Line:", input_line_number, &
                  " Conditional ("//TRIM(cond1)//","//TRIM(cond2)// &
                  ") resolves to true. Continuing parsing."
               WRITE (output_unit, *) TRIM(message)
            END IF
            ! resolves to true. keep on reading normally...
            RETURN
         ELSE
            IF (debug_this_module .AND. output_unit > 0) THEN
               WRITE (UNIT=message, FMT="(3A,I6,A)") "INPP_@IF: in file: ", &
                  TRIM(input_file_name), "  Line:", input_line_number, &
                  " Conditional ("//TRIM(cond1)//","//TRIM(cond2)// &
                  ") resolves to false. Skipping Lines."
               WRITE (output_unit, *) TRIM(message)
            END IF
            istat = 0
            DO WHILE (istat == 0)
               input_line_number = input_line_number + 1
               READ (UNIT=input_unit, FMT="(A)", IOSTAT=istat) input_line
               IF (debug_this_module .AND. output_unit > 0) THEN
                  WRITE (UNIT=message, FMT="(1A,I6,2A)") "INPP_@IF: skipping line ", &
                     input_line_number, ": ", TRIM(input_line)
                  WRITE (output_unit, *) TRIM(message)
               END IF

               indi = INDEX(input_line, "@")
               pos1 = INDEX(input_line, "!")
               pos2 = INDEX(input_line, "#")
               IF (((pos1 > 0) .AND. (pos1 < indi)) .OR. ((pos2 > 0) .AND. (pos2 < indi))) THEN
                  ! Nothing to do
                  CYCLE
               END IF

               ! Get the start of the instruction and find "@KEYWORD"
               indi = MAX(1, indi)
               indf = indi
               DO WHILE (input_line(indf:indf) /= " ")
                  indf = indf + 1
               END DO
               CPASSERT((indf - indi) <= default_string_length)
               mytag = input_line(indi:indf - 1)
               CALL uppercase(mytag)
               IF (INDEX(mytag, "@ENDIF") > 0) THEN
                  ! ok found it. go back to normal
                  IF (debug_this_module .AND. output_unit > 0) THEN
                     WRITE (output_unit, *) "INPP_@IF: found @ENDIF. End of skipping."
                  END IF
                  RETURN
               END IF
            END DO
            IF (istat /= 0) THEN
               WRITE (UNIT=message, FMT="(A,I0)") &
                  "Error while searching for matching @ENDIF directive in file <"// &
                  TRIM(input_file_name)//">  Line:", input_line_number
               CPABORT(TRIM(message))
            END IF
         END IF

      CASE ("@ENDIF")
         ! In normal mode, just skip line and continue
         IF (debug_this_module .AND. output_unit > 0) THEN
            WRITE (UNIT=message, FMT="(A,I0)") &
               TRIM(mytag)//" directive found and ignored in file <"// &
               TRIM(input_file_name)//">  Line: ", input_line_number
         END IF

      CASE ("@PRINT")
         ! For debugging of variables etc.
         IF (output_unit > 0) THEN
            WRITE (UNIT=output_unit, FMT="(T2,A,I0,A)") &
               TRIM(mytag)//" directive in file <"// &
               TRIM(input_file_name)//">  Line: ", input_line_number, &
               " ->"//TRIM(input_line(indf:))
         END IF

      END SELECT

   END SUBROUTINE inpp_process_directive

! **************************************************************************************************
!> \brief Restore older file status from stack after EOF on include file.
!> \param inpp ...
!> \param input_file_name ...
!> \param input_line_number ...
!> \param input_unit ...
!> \par History
!>      - standalone proof-of-concept implementation (20.02.2008,AK)
!>      - integrated into cp2k (21.02.2008)
!> \author AK
! **************************************************************************************************
   SUBROUTINE inpp_end_include(inpp, input_file_name, input_line_number, input_unit)
      TYPE(inpp_type), POINTER                           :: inpp
      CHARACTER(LEN=*), INTENT(INOUT)                    :: input_file_name
      INTEGER, INTENT(INOUT)                             :: input_line_number, input_unit

      CPASSERT(ASSOCIATED(inpp))
      IF (inpp%io_stack_level > 0) THEN
         CALL close_file(input_unit)
         input_unit = inpp%io_stack_channel(inpp%io_stack_level)
         input_line_number = inpp%io_stack_lineno(inpp%io_stack_level)
         input_file_name = TRIM(inpp%io_stack_filename(inpp%io_stack_level))
         inpp%io_stack_level = inpp%io_stack_level - 1
         CALL reallocate(inpp%io_stack_channel, 1, inpp%io_stack_level)
         CALL reallocate(inpp%io_stack_lineno, 1, inpp%io_stack_level)
         CALL reallocate(inpp%io_stack_filename, 1, inpp%io_stack_level)
      END IF

   END SUBROUTINE inpp_end_include

! **************************************************************************************************
!> \brief expand all ${VAR} or $VAR variable entries on the input string (LTR, no nested vars)
!> \param inpp ...
!> \param input_line ...
!> \param input_file_name ...
!> \param input_line_number ...
!> \par History
!>      - standalone proof-of-concept implementation (22.02.2008,AK)
!>      - integrated into cp2k (23.02.2008)
!> \author AK
! **************************************************************************************************
   SUBROUTINE inpp_expand_variables(inpp, input_line, input_file_name, input_line_number)
      TYPE(inpp_type), POINTER                           :: inpp
      CHARACTER(LEN=*), INTENT(INOUT)                    :: input_line, input_file_name
      INTEGER, INTENT(IN)                                :: input_line_number

      CHARACTER(LEN=default_path_length)                 :: newline
      CHARACTER(LEN=max_message_length)                  :: message
      CHARACTER(LEN=:), ALLOCATABLE                      :: var_value, var_name
      INTEGER                                            :: idx, pos1, pos2, default_val_sep_idx

      CPASSERT(ASSOCIATED(inpp))

      ! process line until all variables named with the convention ${VAR} are expanded
      DO WHILE (INDEX(input_line, '${') > 0)
         pos1 = INDEX(input_line, '${')
         pos1 = pos1 + 2
         pos2 = INDEX(input_line(pos1:), '}')

         IF (pos2 == 0) THEN
            WRITE (UNIT=message, FMT="(3A,I6)") &
               "Missing '}' in file: ", &
               TRIM(input_file_name), "  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         pos2 = pos1 + pos2 - 2
         var_name = input_line(pos1:pos2)

         default_val_sep_idx = INDEX(var_name, '-')

         IF (default_val_sep_idx > 0) THEN
            var_value = var_name(default_val_sep_idx + 1:)
            var_name = var_name(:default_val_sep_idx - 1)
         END IF

         IF (.NOT. is_valid_varname(var_name)) THEN
            WRITE (UNIT=message, FMT="(5A,I6)") &
               "Invalid variable name ${", var_name, "} in file: ", &
               TRIM(input_file_name), "  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         idx = inpp_find_variable(inpp, var_name)

         IF (idx == 0 .AND. default_val_sep_idx == 0) THEN
            WRITE (UNIT=message, FMT="(5A,I6)") &
               "Variable ${", var_name, "} not defined in file: ", &
               TRIM(input_file_name), "  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         IF (idx > 0) &
            var_value = TRIM(inpp%variable_value(idx))

         newline = input_line(1:pos1 - 3)//var_value//input_line(pos2 + 2:)
         input_line = newline
      END DO

      ! process line until all variables named with the convention $VAR are expanded
      DO WHILE (INDEX(input_line, '$') > 0)
         pos1 = INDEX(input_line, '$')
         pos1 = pos1 + 1 ! move to the start of the variable name
         pos2 = INDEX(input_line(pos1:), ' ')

         IF (pos2 == 0) &
            pos2 = LEN_TRIM(input_line(pos1:)) + 1

         pos2 = pos1 + pos2 - 2 ! end of the variable name, minus the separating whitespace
         var_name = input_line(pos1:pos2)
         idx = inpp_find_variable(inpp, var_name)

         IF (.NOT. is_valid_varname(var_name)) THEN
            WRITE (UNIT=message, FMT="(5A,I6)") &
               "Invalid variable name ${", var_name, "} in file: ", &
               TRIM(input_file_name), "  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         IF (idx == 0) THEN
            WRITE (UNIT=message, FMT="(5A,I6)") &
               "Variable $", var_name, " not defined in file: ", &
               TRIM(input_file_name), "  Line:", input_line_number
            CPABORT(TRIM(message))
         END IF

         newline = input_line(1:pos1 - 2)//TRIM(inpp%variable_value(idx))//input_line(pos2 + 1:)
         input_line = newline
      END DO

   END SUBROUTINE inpp_expand_variables

! **************************************************************************************************
!> \brief return index position of a variable in dictionary. 0 if not found.
!> \param inpp ...
!> \param varname ...
!> \return ...
!> \par History
!>      - standalone proof-of-concept implementation (22.02.2008,AK)
!>      - integrated into cp2k (23.02.2008)
!> \author AK
! **************************************************************************************************
   FUNCTION inpp_find_variable(inpp, varname) RESULT(idx)
      TYPE(inpp_type), POINTER                           :: inpp
      CHARACTER(len=*), INTENT(IN)                       :: varname
      INTEGER                                            :: idx

      INTEGER                                            :: i

      idx = 0
      DO i = 1, inpp%num_variables
         IF (TRIM(varname) == TRIM(inpp%variable_name(i))) THEN
            idx = i
            RETURN
         END IF
      END DO
      RETURN
   END FUNCTION inpp_find_variable

! **************************************************************************************************
!> \brief print a list of the variable/value table
!> \param inpp ...
!> \param iochan ...
!> \par History
!>      - standalone proof-of-concept implementation (22.02.2008,AK)
!>      - integrated into cp2k (23.02.2008)
!> \author AK
! **************************************************************************************************
   SUBROUTINE inpp_list_variables(inpp, iochan)
      TYPE(inpp_type), POINTER                           :: inpp
      INTEGER, INTENT(IN)                                :: iochan

      INTEGER                                            :: i

      WRITE (iochan, '(A)') '   #   NAME                   VALUE'
      DO i = 1, inpp%num_variables
         WRITE (iochan, '(I4," | ",A,T30," | ",A," |")') &
            i, TRIM(inpp%variable_name(i)), TRIM(inpp%variable_value(i))
      END DO
   END SUBROUTINE inpp_list_variables

END MODULE cp_parser_inpp_methods
