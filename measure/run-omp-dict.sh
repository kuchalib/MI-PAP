log_file="omp-dictVec.txt"
alphabets=(4 4 16)
rules=(1 1 2)
min=(2 2 "eariotnsEARIOTNS")
max=(2 2 "EARIOTNSeariotns")
original_values=("napalm5e" "azotemic9S", "lupuSErythemAToSus")
hashes=("bd14a2ab2d51782968669b68b17d909f" "b4ba89b4d21e4b5886c8dae0657396d6" "04afd29e779eb8522ec606d7346b7ae7")

echo "Merenicko..." > $log_file

for n in 0 1 2; do
    echo "Computing...${original_values[$n]}"
    echo "Pass;Blocks;Threads;Time" >> $log_file
    for t in 12 10 8 6 4 2
    do
            START=$(date +%s.%N)
            echo -n "$(./a.out 3 words.txt ${hashes[$n]} ${rules[$n]} ${alphabets[$n]} ${min[$n]} ${max[$n]} $t})" >> $log_file
            END=$(date +%s.%N)
            DIFF=$(echo "$END - $START" | bc)
            echo ";${t};${DIFF}" >> $log_file
    done
done
