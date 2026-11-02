/* Analysis input only (never compiled or run): one function with many branch joins, each of
   which merges per-path analysis facts. The analyzer must handle it in bounded memory. */
void *alloc(unsigned n);
void release(void *p);
int pick(int i);

int many_joins(int k) {
  int total = 0;
  if (pick(0) == k) total += 0; else total -= 0;
  if (pick(1) == k) total += 1; else total -= 1;
  if (pick(2) == k) total += 2; else total -= 2;
  if (pick(3) == k) total += 3; else total -= 3;
  if (pick(4) == k) total += 4; else total -= 4;
  if (pick(5) == k) total += 5; else total -= 5;
  if (pick(6) == k) total += 6; else total -= 6;
  if (pick(7) == k) total += 7; else total -= 7;
  if (pick(8) == k) total += 8; else total -= 8;
  if (pick(9) == k) total += 9; else total -= 9;
  if (pick(10) == k) total += 10; else total -= 10;
  if (pick(11) == k) total += 11; else total -= 11;
  if (pick(12) == k) total += 12; else total -= 12;
  if (pick(13) == k) total += 13; else total -= 13;
  if (pick(14) == k) total += 14; else total -= 14;
  if (pick(15) == k) total += 15; else total -= 15;
  if (pick(16) == k) total += 16; else total -= 16;
  if (pick(17) == k) total += 17; else total -= 17;
  if (pick(18) == k) total += 18; else total -= 18;
  if (pick(19) == k) total += 19; else total -= 19;
  if (pick(20) == k) total += 20; else total -= 20;
  if (pick(21) == k) total += 21; else total -= 21;
  if (pick(22) == k) total += 22; else total -= 22;
  if (pick(23) == k) total += 23; else total -= 23;
  if (pick(24) == k) total += 24; else total -= 24;
  if (pick(25) == k) total += 25; else total -= 25;
  if (pick(26) == k) total += 26; else total -= 26;
  if (pick(27) == k) total += 27; else total -= 27;
  if (pick(28) == k) total += 28; else total -= 28;
  if (pick(29) == k) total += 29; else total -= 29;
  if (pick(30) == k) total += 30; else total -= 30;
  if (pick(31) == k) total += 31; else total -= 31;
  if (pick(32) == k) total += 32; else total -= 32;
  if (pick(33) == k) total += 33; else total -= 33;
  if (pick(34) == k) total += 34; else total -= 34;
  if (pick(35) == k) total += 35; else total -= 35;
  if (pick(36) == k) total += 36; else total -= 36;
  if (pick(37) == k) total += 37; else total -= 37;
  if (pick(38) == k) total += 38; else total -= 38;
  if (pick(39) == k) total += 39; else total -= 39;
  if (pick(40) == k) total += 40; else total -= 40;
  if (pick(41) == k) total += 41; else total -= 41;
  if (pick(42) == k) total += 42; else total -= 42;
  if (pick(43) == k) total += 43; else total -= 43;
  if (pick(44) == k) total += 44; else total -= 44;
  if (pick(45) == k) total += 45; else total -= 45;
  if (pick(46) == k) total += 46; else total -= 46;
  if (pick(47) == k) total += 47; else total -= 47;
  if (pick(48) == k) total += 48; else total -= 48;
  if (pick(49) == k) total += 49; else total -= 49;
  if (pick(50) == k) total += 50; else total -= 50;
  if (pick(51) == k) total += 51; else total -= 51;
  if (pick(52) == k) total += 52; else total -= 52;
  if (pick(53) == k) total += 53; else total -= 53;
  if (pick(54) == k) total += 54; else total -= 54;
  if (pick(55) == k) total += 55; else total -= 55;
  if (pick(56) == k) total += 56; else total -= 56;
  if (pick(57) == k) total += 57; else total -= 57;
  if (pick(58) == k) total += 58; else total -= 58;
  if (pick(59) == k) total += 59; else total -= 59;
  if (pick(60) == k) total += 60; else total -= 60;
  if (pick(61) == k) total += 61; else total -= 61;
  if (pick(62) == k) total += 62; else total -= 62;
  if (pick(63) == k) total += 63; else total -= 63;
  return total;
}

int many_gotos_into_blocks(int k) {
  int v = 0;
  if (k > 0) {
    switch (k) {
    case 0:
      if (pick(0)) goto fail_a;
      if (pick(100)) goto fail_b;
      v += 1;
      break;
    case 1:
      if (pick(1)) goto fail_a;
      if (pick(101)) goto fail_b;
      v += 1;
      break;
    case 2:
      if (pick(2)) goto fail_a;
      if (pick(102)) goto fail_b;
      v += 1;
      break;
    case 3:
      if (pick(3)) goto fail_a;
      if (pick(103)) goto fail_b;
      v += 1;
      break;
    case 4:
      if (pick(4)) goto fail_a;
      if (pick(104)) goto fail_b;
      v += 1;
      break;
    case 5:
      if (pick(5)) goto fail_a;
      if (pick(105)) goto fail_b;
      v += 1;
      break;
    case 6:
      if (pick(6)) goto fail_a;
      if (pick(106)) goto fail_b;
      v += 1;
      break;
    case 7:
      if (pick(7)) goto fail_a;
      if (pick(107)) goto fail_b;
      v += 1;
      break;
    case 8:
      if (pick(8)) goto fail_a;
      if (pick(108)) goto fail_b;
      v += 1;
      break;
    case 9:
      if (pick(9)) goto fail_a;
      if (pick(109)) goto fail_b;
      v += 1;
      break;
    case 10:
      if (pick(10)) goto fail_a;
      if (pick(110)) goto fail_b;
      v += 1;
      break;
    case 11:
      if (pick(11)) goto fail_a;
      if (pick(111)) goto fail_b;
      v += 1;
      break;
    case 99:
      if (pick(99)) {
      fail_a:
        return -1;
      }
      if (pick(98)) {
      fail_b:
        return -2;
      }
      break;
    default:
      goto slow;
    }
    return v;
  } else {
  slow:
    return pick(k);
  }
}
