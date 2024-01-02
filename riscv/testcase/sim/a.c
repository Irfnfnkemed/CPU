#include "io.h"
int main()
{   
    int a[10][5];
    int b[8];
    b[6] = 8;
    a[b[6]][4] = 9;
    outlln(a[8][4]);
    return 0;
}
