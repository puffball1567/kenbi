// @kenbi
/* STATE B — honestly annotated (the bug is still here).
   Cross-function flow (variant 41): the allocation and the first free are in
   bad(), the second free is in badSink(). We add ONLY the honest contracts:
     - badSink / goodG2BSink FREE their argument        -> @frees(data)
     - goodB2GSink only borrows it (does nothing)        -> @borrows(data)
     - each buffer is a heap resource owned by `data`    -> @mem
   With badSink declared @frees, bad()'s free(data) + badSink(data) is a
   DOUBLE_FREE *across functions* — the honest contract makes the cross-function
   bug provable, it does not annotate it away.
   NOTE: goodB2G() frees data and then passes that freed pointer to a borrowing
   sink; kenbi flags USE_AFTER_FREE on the freed-pointer *value* (UB per C11
   6.2.4/7.22.3) — stricter than Juliet, defensible. goodG2B() is the GREEN one. */
/* TEMPLATE GENERATED TESTCASE FILE
Filename: CWE415_Double_Free__malloc_free_char_41.c
*/
/*
 * CWE: 415 Double Free
 * Flow Variant: 41 Data passed as an argument from one function to another
 * */

#include "std_testcase.h"

#include <wchar.h>

#ifndef OMITBAD

// @frees(data)
static void badSink(char * data)
{
    /* POTENTIAL FLAW: Possibly freeing memory twice */
    free(data);
}

void CWE415_Double_Free__malloc_free_char_41_bad()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    /* POTENTIAL FLAW: Free data in the source - the bad sink frees data as well */
    free(data);
    badSink(data);
}

#endif /* OMITBAD */

#ifndef OMITGOOD

/* goodG2B uses the GoodSource with the BadSink */
// @frees(data)
static void goodG2BSink(char * data)
{
    free(data);
}

static void goodG2B()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    /* FIX: Do NOT free data in the source - the sink frees data */
    goodG2BSink(data);
}

/* goodB2G uses the BadSource with the GoodSink */
// @borrows(data)
static void goodB2GSink(char * data)
{
    /* FIX: Don't attempt to free the memory */
    ; /* empty statement needed for some flow variants */
}

static void goodB2G()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    /* POTENTIAL FLAW: Free data in the source - the bad sink frees data as well */
    free(data);
    goodB2GSink(data);
}

void CWE415_Double_Free__malloc_free_char_41_good()
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
    CWE415_Double_Free__malloc_free_char_41_good();
    printLine("Finished good()");
#endif /* OMITGOOD */
#ifndef OMITBAD
    printLine("Calling bad()...");
    CWE415_Double_Free__malloc_free_char_41_bad();
    printLine("Finished bad()");
#endif /* OMITBAD */
    return 0;
}

#endif
