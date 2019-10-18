#include <stdio.h>
#include <stdlib.h>

/* run this program using the console pauser or add your own getch, system("pause") or input loop */
long long int get_PRN(int x);
void display_PRN(long long int x,int a);
int main() 
{
	long long int prns[5];
	int i=0;
	for(i=0;i<5;i++)
	prns[i]=get_PRN(i+1);
	printf("Thanks for entering the PRN of the students.......\nThe list of PRN is as follows:-\n");
	for(i=0;i<5;i++)
	display_PRN(prns[i],(i+1));
	return 0;
}
long long int get_PRN(int x)
{
	long long int l;
	printf("Enter the PRN at position %d:",x);
	scanf("%llu",&l);
    return(l);
}
void display_PRN(long long int x,int a)
{
	printf("%d>%llu\n\n",a,x);
}
