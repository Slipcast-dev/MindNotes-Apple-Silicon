using System;
using System.Linq;

namespace Demo
{
    public class Program
    {
        // Prints the squares of 1..5.
        public static void Main(string[] args)
        {
            var squares = Enumerable.Range(1, 5).Select(n => n * n);
            Console.WriteLine($"Squares: {string.Join(", ", squares)}");
        }
    }
}
