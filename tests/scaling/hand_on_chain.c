/* Analysis input only (never compiled or run): ownership handed on one variable per
   iteration. A short chain converges within the loop analysis limit; a long one does not,
   and must then be refused rather than judged from an incomplete view. */
#include <stdlib.h>
int hand_on_6(int k) {
  /* @mem demo::b0 { free: free, owner: p0 } */
  char *p0 = malloc(8);
  /* @mem demo::b1 { free: free, owner: p1 } */
  char *p1 = malloc(8);
  /* @mem demo::b2 { free: free, owner: p2 } */
  char *p2 = malloc(8);
  /* @mem demo::b3 { free: free, owner: p3 } */
  char *p3 = malloc(8);
  /* @mem demo::b4 { free: free, owner: p4 } */
  char *p4 = malloc(8);
  /* @mem demo::b5 { free: free, owner: p5 } */
  char *p5 = malloc(8);
  /* @mem demo::b6 { free: free, owner: p6 } */
  char *p6 = malloc(8);
  for (int i = 0; i < k; i++) {
    free(p6);
    p6 = p5;
    p5 = p4;
    p4 = p3;
    p3 = p2;
    p2 = p1;
    p1 = p0;
    p0 = malloc(8);
  }
  free(p0);
  free(p1);
  free(p2);
  free(p3);
  free(p4);
  free(p5);
  free(p6);
  return 0;
}

int hand_on_20(int k) {
  /* @mem demo::b0 { free: free, owner: p0 } */
  char *p0 = malloc(8);
  /* @mem demo::b1 { free: free, owner: p1 } */
  char *p1 = malloc(8);
  /* @mem demo::b2 { free: free, owner: p2 } */
  char *p2 = malloc(8);
  /* @mem demo::b3 { free: free, owner: p3 } */
  char *p3 = malloc(8);
  /* @mem demo::b4 { free: free, owner: p4 } */
  char *p4 = malloc(8);
  /* @mem demo::b5 { free: free, owner: p5 } */
  char *p5 = malloc(8);
  /* @mem demo::b6 { free: free, owner: p6 } */
  char *p6 = malloc(8);
  /* @mem demo::b7 { free: free, owner: p7 } */
  char *p7 = malloc(8);
  /* @mem demo::b8 { free: free, owner: p8 } */
  char *p8 = malloc(8);
  /* @mem demo::b9 { free: free, owner: p9 } */
  char *p9 = malloc(8);
  /* @mem demo::b10 { free: free, owner: p10 } */
  char *p10 = malloc(8);
  /* @mem demo::b11 { free: free, owner: p11 } */
  char *p11 = malloc(8);
  /* @mem demo::b12 { free: free, owner: p12 } */
  char *p12 = malloc(8);
  /* @mem demo::b13 { free: free, owner: p13 } */
  char *p13 = malloc(8);
  /* @mem demo::b14 { free: free, owner: p14 } */
  char *p14 = malloc(8);
  /* @mem demo::b15 { free: free, owner: p15 } */
  char *p15 = malloc(8);
  /* @mem demo::b16 { free: free, owner: p16 } */
  char *p16 = malloc(8);
  /* @mem demo::b17 { free: free, owner: p17 } */
  char *p17 = malloc(8);
  /* @mem demo::b18 { free: free, owner: p18 } */
  char *p18 = malloc(8);
  /* @mem demo::b19 { free: free, owner: p19 } */
  char *p19 = malloc(8);
  /* @mem demo::b20 { free: free, owner: p20 } */
  char *p20 = malloc(8);
  for (int i = 0; i < k; i++) {
    free(p20);
    p20 = p19;
    p19 = p18;
    p18 = p17;
    p17 = p16;
    p16 = p15;
    p15 = p14;
    p14 = p13;
    p13 = p12;
    p12 = p11;
    p11 = p10;
    p10 = p9;
    p9 = p8;
    p8 = p7;
    p7 = p6;
    p6 = p5;
    p5 = p4;
    p4 = p3;
    p3 = p2;
    p2 = p1;
    p1 = p0;
    p0 = malloc(8);
  }
  free(p0);
  free(p1);
  free(p2);
  free(p3);
  free(p4);
  free(p5);
  free(p6);
  free(p7);
  free(p8);
  free(p9);
  free(p10);
  free(p11);
  free(p12);
  free(p13);
  free(p14);
  free(p15);
  free(p16);
  free(p17);
  free(p18);
  free(p19);
  free(p20);
  return 0;
}
