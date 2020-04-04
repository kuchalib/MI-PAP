log_file="omp-brutVec.txt"
alphabets=(4, 4, 5, 5)
min=(5, 4, 4, 4)
max=(5, 4, 4, 5)
original_values=("99999" "9999" "~A9C" "J@K1!")
hashes=("d3eb9a9233e52948740d7eb8c3062d14" "fa246d0262c3925617b0c72bb20eeb1d" "7acb9edf8d0b177c14f95855d082853f" "2670fc38ccfa50ccc3ba4d8d4ef896f9")

echo "Merenicko..." > $log_file

for n in 0 1 2 3; do
    echo "Computing...${original_values[$n]}"
    echo "Pass;Threads;Time" >> $log_file
    for t in 2 4 6 8 10 12
    do
      START=$(date +%s.%N)
      echo -n "$(./a.out 2 ${alphabets[$n]} ${hashes[$n]} ${min[$n]} ${max[$n]} $t})" >> $log_file
      END=$(date +%s.%N)
      DIFF=$(echo "$END - $START" | bc)
      echo ";${t};${DIFF}" >> $log_file
    done
done
