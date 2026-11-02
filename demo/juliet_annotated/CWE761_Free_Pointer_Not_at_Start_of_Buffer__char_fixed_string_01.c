// @kenbi
/* STATE B — honestly annotated (the bug is still here).
   Same logic as the Juliet original; we add ONLY the honest intent: the buffer
   is a heap resource freed with free(), owned by `data`, and printLine borrows
   its argument. bad() advances `data` with data++ and then frees that advanced
   (interior) pointer — that must STILL be RED. */
/* TEMPLATE GENERATED TESTCASE FILE
Filename: CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01.c
*/
/*
 * CWE: 761 Free Pointer not at Start of Buffer
 * Flow Variant: 01 Baseline
 * */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

#define BAD_SOURCE_FIXED_STRING "Fixed String"
#define SEARCH_CHAR 'S'

#ifndef OMITBAD

void CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01_bad()
{
    char * data;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    data[0] = '\0';
    strcpy(data, BAD_SOURCE_FIXED_STRING);
    /* FLAW: incrementing the pointer, then freeing it not at the start of the buffer */
    for (; *data != '\0'; data++)
    {
        if (*data == SEARCH_CHAR)
        {
            printLine("We have a match!");
            break;
        }
    }
    free(data);
}

#endif /* OMITBAD */

#ifndef OMITGOOD

/* goodB2G() uses the BadSource with the GoodSink */
static void goodB2G()
{
    char * data;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    data[0] = '\0';
    strcpy(data, BAD_SOURCE_FIXED_STRING);
    {
        size_t i;
        /* FIX: traverse with an index so `data` still points at the start */
        for (i=0; i < strlen(data); i++)
        {
            if (data[i] == SEARCH_CHAR)
            {
                printLine("We have a match!");
                break;
            }
        }
        free(data);
    }
}

void CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01_good()
{
    goodB2G();
}

#endif /* OMITGOOD */

#ifdef INCLUDEMAIN

int main(int argc, char * argv[])
{
    srand( (unsigned)time(NULL) );
#ifndef OMITGOOD
    printLine("Calling good()...");
    CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01_good();
    printLine("Finished good()");
#endif /* OMITGOOD */
#ifndef OMITBAD
    printLine("Calling bad()...");
    CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01_bad();
    printLine("Finished bad()");
#endif /* OMITBAD */
    return 0;
}

#endif
