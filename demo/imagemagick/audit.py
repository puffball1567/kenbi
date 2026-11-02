"""For a MagickCore file:line, print the enclosing function with every mention of the
leaked variable and every `return`, so a leak finding can be classified by reading the exits."""
import os, sys, re
IM = os.environ.get('MAGICK_SRC', '../imagemagick-pilot/orig/MagickCore') + '/'

def enclosing(lines, ln):
    # a definition line starts at column 0 and is not a comment/preprocessor/brace
    start = 0
    for i in range(ln - 1, -1, -1):
        s = lines[i]
        if s and s[0] not in ' \t#%/*}' and '(' in s:
            start = i
            break
        if s.startswith('{') and i > 0:
            # K&R-ish: the signature is the line(s) above
            for j in range(i - 1, -1, -1):
                if lines[j] and lines[j][0] not in ' \t#%/*':
                    start = j
                    break
            break
    end = len(lines)
    for i in range(ln, len(lines)):
        if lines[i].startswith('}'):
            end = i + 1
            break
    return start, end

for spec in sys.argv[1:]:
    f, ln = spec.rsplit(':', 1)
    ln = int(ln)
    lines = open(IM + f, errors='replace').read().split('\n')
    var, allocln = None, ln
    ALLOC = re.compile(r'\b(Acquire\w*Memory|AcquireString|ConstantString|CloneString|AcquireCriticalMemory|Acquire\w+Info|GetThresholdMap|ConvertPathToPolygon)\s*\(')
    for cand in [ln] + [ln + d for d in range(1, 4)] + [ln - d for d in range(1, 4)]:
        if not (1 <= cand <= len(lines)): continue
        t = lines[cand - 1]
        if not ALLOC.search(t): continue
        m = re.match(r'\s*(?:\(void\)\s*)?([A-Za-z_][\w]*)\s*(?:->\s*([A-Za-z_]\w*)\s*)?=', t)
        if m:
            var, allocln = (m.group(2) or m.group(1)), cand
            break
    s, e = enclosing(lines, ln)
    print(f"########## {f}:{ln}   fn starts {s+1}, ends {e}   var={var}")
    print(f"  ALLOC {allocln}: {lines[allocln-1].strip()[:110]}")
    for i in range(s, e):
        t = lines[i]
        hit_ret = re.search(r'\breturn\b', t)
        hit_var = var and re.search(r'\b' + re.escape(var) + r'\b', t)
        if hit_ret or (hit_var and i + 1 != allocln):
            tag = 'RET ' if hit_ret else '    '
            print(f"  {tag}{i+1}: {t.strip()[:110]}")
    print()
