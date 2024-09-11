
int calc(int x, int y)
{
    // this is a simple function we can disasemble
    volatile int val = 0;
    return x + y + val;
}
