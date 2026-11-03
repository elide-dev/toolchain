// rustc -nodefaultlibs plus TSAN cleanups requires this compiler-rt personality.
extern int __gcc_personality_v0(void);
int (*volatile personality)(void) = __gcc_personality_v0;
int main(void) { return personality == 0; }
