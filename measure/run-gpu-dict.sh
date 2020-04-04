log_file="gpu-dict.txt"
alphabets=(4 0 4)
min=(2 3 4)
max=(2 4 4)
original_values=("napalm5e" "NORAD3411" "azotemic9S")
hashes=("bd14a2ab2d51782968669b68b17d909f" "882552e781a7bf3c1300c7e1b474b9e6" "b4ba89b4d21e4b5886c8dae0657396d6")

echo "Merenicko..." > $log_file

for n in 0 1 2; do
    echo "Computing...${original_values[$n]}"
    echo "Pass;Blocks;Threads;Time" >> $log_file
    for t in 64 96 128
    do
        for b in 16 32 48 64 80 96 112 128 144 160
        do
            START=$(date +%s.%N)
            echo -n "$(./a.out 3 words.txt ${hashes[$n]} 1 ${alphabets[$n]} ${min[$n]} ${max[$n]} $b $t})" >> $log_file
            END=$(date +%s.%N)
            DIFF=$(echo "$END - $START")
            echo ";${b};${t};${DIFF}" >> $log_file
        done
    done
done
