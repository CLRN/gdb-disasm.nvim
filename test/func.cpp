
int calc(int x, int y)
{
    volatile int val = 0;
    return x + y + val;
}
