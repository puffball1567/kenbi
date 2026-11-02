// @kenbi
/* STATE B — honestly annotated (the bug is still here).
   bad() points `data` at a STACK array (dataBuffer[100]) and then free()s it.
   There is no honest @mem for it — it is not a heap resource — so the honest
   annotation adds nothing that could legitimize the free; freeing non-heap
   memory must STILL be RED. goodG2B() allocates on the heap, so it gets the
   honest @mem (owner: dataBuffer) and is GREEN. printLine borrows its arg. */
/* TEMPLATE GENERATED TESTCASE FILE
Filename: CWE590_Free_Memory_Not_on_Heap__free_char_declare_01.c
*/
/*
 * CWE: 590 Free Memory Not on Heap
 * Flow Variant: 01 Baseline
 * */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

#ifndef OMITBAD

void CWE590_Free_Memory_Not_on_Heap__free_char_declare_01_bad()
{
    char * data;
    data = NULL; /* Initialize data */
    {
        /* FLAW: data is allocated on the stack and deallocated in the BadSink */
        char dataBuffer[100];
        memset(dataBuffer, 'A', 100-1); /* fill with 'A's */
        dataBuffer[100-1] = '\0'; /* null terminate */
        data = dataBuffer;
    }
    printLine(data);
    /* FLAW: deallocating memory that lives on the stack, not the heap */
    free(data);
}

#endif /* OMITBAD */

#ifndef OMITGOOD

/* goodG2B uses the GoodSource with the BadSink */
static void goodG2B()
{
    char * data;
    data = NULL; /* Initialize data */
    {
        /* FIX: data is allocated on the heap and deallocated in the BadSink */
        /* @mem g::buf { free: free, owner: dataBuffer } */
        char * dataBuffer = (char *)malloc(100*sizeof(char));
        if (dataBuffer == NULL)
        {
            printLine("malloc() failed");
            exit(1);
        }
        memset(dataBuffer, 'A', 100-1); /* fill with 'A's */
        dataBuffer[100-1] = '\0'; /* null terminate */
        data = dataBuffer;
    }
    printLine(data);
    free(data);
}

void CWE590_Free_Memory_Not_on_Heap__free_char_declare_01_good()
{
    goodG2B();
}

#endif /* OMITGOOD */

#ifdef INCLUDEMAIN

int main(int argc, char * argv[])
{
    srand( (unsigned)time(NULL) );
#ifndef OMITGOOD
    printLine("Calling good()...");
    CWE590_Free_Memory_Not_on_Heap__free_char_declare_01_good();
    printLine("Finished good()");
#endif /* OMITGOOD */
#ifndef OMITBAD
    printLine("Calling bad()...");
    CWE590_Free_Memory_Not_on_Heap__free_char_declare_01_bad();
    printLine("Finished bad()");
#endif /* OMITBAD */
    return 0;
}

#endif
