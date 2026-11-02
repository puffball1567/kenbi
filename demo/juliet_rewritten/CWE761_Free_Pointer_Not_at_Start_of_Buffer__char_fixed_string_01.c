// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   The free-not-at-start is gone: `data` is never advanced — the string is
   traversed with an INDEX, so `data` still addresses the start of the buffer
   when it is freed. The owned heap buffer is freed exactly once, at its start. */
/*
 * CWE: 761 Free Pointer not at Start of Buffer — fixed.
 */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

#define BAD_SOURCE_FIXED_STRING "Fixed String"
#define SEARCH_CHAR 'S'

void CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01_fixed()
{
    char * data;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    data[0] = '\0';
    strcpy(data, BAD_SOURCE_FIXED_STRING);
    {
        size_t i;
        /* FIXED: traverse with an index so `data` still points at the start */
        for (i = 0; i < strlen(data); i++)
        {
            if (data[i] == SEARCH_CHAR)
            {
                printLine("We have a match!");
                break;
            }
        }
        /* FIXED: free at the start of the buffer, exactly once */
        free(data);
    }
}
