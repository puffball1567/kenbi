// @kenbi
/* STATE B — honestly annotated (the bug is still here).
   Cross-function flow (variant 41): bad() allocates and hands the buffer to a
   sink. We add ONLY the honest contracts:
     - badSink / goodG2BSink do nothing with the buffer -> @borrows(data)
     - goodB2GSink frees it                              -> @frees(data)
     - printLine borrows its argument                    -> @borrows(line)
     - each heap buffer is a resource owned by `data`    -> @mem
   Because badSink only borrows, ownership stays in bad(), which never frees it:
   LEAK. The honest contract pins the leak to bad(), it does not hide it.
   goodG2B() uses stack memory (ALLOCA, no @mem); goodB2G()'s sink frees — both GREEN. */
/* TEMPLATE GENERATED TESTCASE FILE
Filename: CWE401_Memory_Leak__char_malloc_41.c
*/
/*
 * CWE: 401 Memory Leak
 * Flow Variant: 41 Data passed as an argument from one function to another
 * */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

#ifndef OMITBAD

// @borrows(data)
static void badSink(char * data)
{
    ; /* empty statement needed for some flow variants */
}

void CWE401_Memory_Leak__char_malloc_41_bad()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    strcpy(data, "A String");
    printLine(data);
    badSink(data);
}

#endif /* OMITBAD */

#ifndef OMITGOOD

// @borrows(data)
static void goodG2BSink(char * data)
{
    ; /* empty statement needed for some flow variants */
}

static void goodG2B()
{
    char * data;
    data = NULL;
    /* GoodSource: stack memory (ALLOCA) — not a heap resource, nothing to free */
    data = (char *)ALLOCA(100*sizeof(char));
    strcpy(data, "A String");
    printLine(data);
    goodG2BSink(data);
}

// @frees(data)
static void goodB2GSink(char * data)
{
    free(data);
}

static void goodB2G()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    strcpy(data, "A String");
    printLine(data);
    goodB2GSink(data);
}

void CWE401_Memory_Leak__char_malloc_41_good()
{
    goodB2G();
    goodG2B();
}

#endif /* OMITGOOD */

#ifdef INCLUDEMAIN

int main(int argc, char * argv[])
{
    srand( (unsigned)time(NULL) );
#ifndef OMITGOOD
    printLine("Calling good()...");
    CWE401_Memory_Leak__char_malloc_41_good();
    printLine("Finished good()");
#endif /* OMITGOOD */
#ifndef OMITBAD
    printLine("Calling bad()...");
    CWE401_Memory_Leak__char_malloc_41_bad();
    printLine("Finished bad()");
#endif /* OMITBAD */
    return 0;
}

#endif
