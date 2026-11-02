// @kenbi
/* STATE B — honestly annotated (the bug is still here). CROSS-FILE (variant 22):
   the allocation and first free are here in 22a; the sink that frees again lives
   in 22b. The honest contract is declared on the PROTOTYPE the caller sees (kenbi
   analyses each file independently, so the cross-file contract rides the
   declaration). With badSink declared @frees, bad()'s free(data) + badSink(data)
   is a DOUBLE_FREE proven across the file boundary.
     - badSink / goodG2BSink free their argument   -> @frees(data)
     - goodB2G1Sink / goodB2G2Sink never free it    -> @borrows(data)
   NOTE: goodB2G1/goodB2G2 free data and then pass that freed pointer to a borrowing
   sink — kenbi flags USE_AFTER_FREE on the freed-pointer value (UB per C11 6.2.4),
   stricter than Juliet but defensible. goodG2B (no local free, sink frees) is GREEN. */
/* TEMPLATE GENERATED TESTCASE FILE  CWE415_Double_Free__malloc_free_char_22a.c */

#include "std_testcase.h"

#include <wchar.h>

#ifndef OMITBAD

int CWE415_Double_Free__malloc_free_char_22_badGlobal = 0;

// @frees(data)
void CWE415_Double_Free__malloc_free_char_22_badSink(char * data);

void CWE415_Double_Free__malloc_free_char_22_bad()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    free(data);
    CWE415_Double_Free__malloc_free_char_22_badGlobal = 1; /* true */
    CWE415_Double_Free__malloc_free_char_22_badSink(data);   /* frees again -> DOUBLE_FREE */
}

#endif /* OMITBAD */

#ifndef OMITGOOD

int CWE415_Double_Free__malloc_free_char_22_goodB2G1Global = 0;
int CWE415_Double_Free__malloc_free_char_22_goodB2G2Global = 0;
int CWE415_Double_Free__malloc_free_char_22_goodG2BGlobal = 0;

// @borrows(data)
void CWE415_Double_Free__malloc_free_char_22_goodB2G1Sink(char * data);

static void goodB2G1()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    free(data);
    CWE415_Double_Free__malloc_free_char_22_goodB2G1Global = 0; /* false */
    CWE415_Double_Free__malloc_free_char_22_goodB2G1Sink(data);
}

// @borrows(data)
void CWE415_Double_Free__malloc_free_char_22_goodB2G2Sink(char * data);

static void goodB2G2()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    free(data);
    CWE415_Double_Free__malloc_free_char_22_goodB2G2Global = 1; /* true */
    CWE415_Double_Free__malloc_free_char_22_goodB2G2Sink(data);
}

// @frees(data)
void CWE415_Double_Free__malloc_free_char_22_goodG2BSink(char * data);

static void goodG2B()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    CWE415_Double_Free__malloc_free_char_22_goodG2BGlobal = 1; /* true */
    /* FIX: do not free here — the sink takes ownership and frees it */
    CWE415_Double_Free__malloc_free_char_22_goodG2BSink(data);
}

void CWE415_Double_Free__malloc_free_char_22_good()
{
    goodB2G1();
    goodB2G2();
    goodG2B();
}

#endif /* OMITGOOD */
