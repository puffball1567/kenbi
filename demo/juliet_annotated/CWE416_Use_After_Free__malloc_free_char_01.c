// @kenbi
/* STATE B — honestly annotated (the bug is still here).
   Same logic as the Juliet original; we add ONLY the honest intent: printLine
   borrows its argument, and the buffer is a heap resource freed with free(),
   owned by `data`. The use-after-free in bad() must STILL be RED.
   NOTE: goodG2B() never frees its buffer, so under honest annotation it is RED
   for LEAK — that is a real incidental leak Juliet itself documents, not a false
   alarm. goodB2G() (allocate, use, free) is the one that goes GREEN. */
/* TEMPLATE GENERATED TESTCASE FILE
Filename: CWE416_Use_After_Free__malloc_free_char_01.c
Label Definition File: CWE416_Use_After_Free__malloc_free.label.xml
Template File: sources-sinks-01.tmpl.c
*/
/*
 * @description
 * CWE: 416 Use After Free
 * Flow Variant: 01 Baseline
 * */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

#ifndef OMITBAD

void CWE416_Use_After_Free__malloc_free_char_01_bad()
{
    char * data;
    /* Initialize data */
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    memset(data, 'A', 100-1);
    data[100-1] = '\0';
    /* POTENTIAL FLAW: Free data in the source - the bad sink attempts to use data */
    free(data);
    /* POTENTIAL FLAW: Use of data that may have been freed */
    printLine(data);
}

#endif /* OMITBAD */

#ifndef OMITGOOD

/* goodG2B uses the GoodSource with the BadSink (never frees -> incidental LEAK) */
static void goodG2B()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    memset(data, 'A', 100-1);
    data[100-1] = '\0';
    /* FIX (for UAF): Do not free data in the source */
    printLine(data);
}

/* goodB2G uses the BadSource with the GoodSink */
static void goodB2G()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    memset(data, 'A', 100-1);
    data[100-1] = '\0';
    /* FIX: free, and then do NOT use data afterwards */
    free(data);
    ; /* empty statement needed for some flow variants */
}

void CWE416_Use_After_Free__malloc_free_char_01_good()
{
    goodG2B();
    goodB2G();
}

#endif /* OMITGOOD */

#ifdef INCLUDEMAIN

int main(int argc, char * argv[])
{
    srand( (unsigned)time(NULL) );
#ifndef OMITGOOD
    printLine("Calling good()...");
    CWE416_Use_After_Free__malloc_free_char_01_good();
    printLine("Finished good()");
#endif /* OMITGOOD */
#ifndef OMITBAD
    printLine("Calling bad()...");
    CWE416_Use_After_Free__malloc_free_char_01_bad();
    printLine("Finished bad()");
#endif /* OMITBAD */
    return 0;
}

#endif
