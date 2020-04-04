log_file="gpu-brut.txt"
alphabets=(4, 4, 4, 5, 5)
min=(5, 4, 6, 4, 4)
max=(5, 4, 6, 4, 5)
original_values=("99999" "9999" "zebra1" "~A9C" "J@K1!")
hashes=("d3eb9a9233e52948740d7eb8c3062d14" "fa246d0262c3925617b0c72bb20eeb1d" "d85fb95cb761f5874f35ce32c305739b" "7acb9edf8d0b177c14f95855d082853f" "2670fc38ccfa50ccc3ba4d8d4ef896f9")

echo "Merenicko..." > $log_file

for n in 0 1 2 3 4; do
    echo "Computing...${original_values[$n]}"
    echo "Pass;Blocks;Threads;Time" >> $log_file
    for t in 64 96 128
    do
        for b in 16 32 48 64 80 96 112 128 144 160
        do
            START=$(date +%s.%N)
            echo -n "$(./a.out 2 ${alphabets[$n]} ${hashes[$n]} ${min[$n]} ${max[$n]} $b $t})" >> $log_file
            END=$(date +%s.%N)
            DIFF=$(echo "$END - $START" | bc)
            echo ";${b};${t};${DIFF}" >> $log_file
        done
    done
done
