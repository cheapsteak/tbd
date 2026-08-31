import sys,time
o=open(sys.argv[1],'a',buffering=1)
f=sys.stdin.buffer
while True:
    b=f.read1(65536)
    if not b: break
    o.write(f'{time.time():.6f} {b!r}\n')
