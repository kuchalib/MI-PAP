#define _CRT_SECURE_NO_WARNINGS
extern "C" {
#include "md5seq.h"
}

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <ctype.h>
#include <math.h>
#include <omp.h>



#define THRESHOLD 1000
#define OMP_THRESHOLD 1000
#define OMP_WORDS_PER_CORE 5000
#define OMP_MAX_WORD_LEN 255
#define OMP_DICTIONARY_THRESHOLD 100
#define DICTIONARY_THRESHOLD 250
#define MAX_ALPHABET_SIZE 95
#define MAX_RULES_COUNT 5
#define ADD_BACK 1
#define SUBSTITUTE 2
#define MAX(x, y) (((x) > (y)) ? (x) : (y))


char tnumbers[11] = "0123456789";
char tlowercase[27] = "abcdefghijklmnopqrstuvwxyz";
char tuppercase[27] = "ABCDEFGHIJKLMNOPQRTSUVWXYZ";
char tlowerupper[53] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRTSUVWXYZ";
char tloweruppernums[63] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRTSUVWXYZ0123456789";
char allchars[95] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRTSUVWXYZ0123456789!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";


char * alph[6] = { &tnumbers[0], &tlowercase[0], &tuppercase[0], &tlowerupper[0], &tloweruppernums[0], allchars };
char sizes[6] = { 10, 26, 26, 52, 62, 94 };
int limits[6] = { 19, 13, 13, 11, 10, 9 }; // max word length

char * charToSubs;
char * subsChar;
size_t charToSubsCount;

char * valuePlaceholder;
int cores; 
bool found = false; 
bool rules2 = false; 

#pragma region CPU
void isHashEqualNew(uint32_t * hash1, uint32_t * hash2, bool * ret)
{
	*ret = true;
	for (int i = 0; i < 4; i++)
	{
		if (hash1[i] != hash2[i])
		{
			*ret = false;
			return;
		}
	}
}

// nerekurzivni volani - idealni pro GPU?
// initialPermutation nastavi pocatecni kombinaci pismen, toto se zjisti tak, ze se vezme pocatecni hodnota pro dane vlakno a postupne se vymoduli/vydeli toto cislo a ziska se tim permutace. 
//Bude to fungovat podobne jako kdyz se napr. desitkove cislo prevadi na sestnactkove, count urcuje pocet iteraci
// stringLength - delka editovaneho textu
// totalStringLength - celkova delka textu
// text - zacatek editace
// textStartAddress - pocatecni adresa textu
char * bruteForceStepNew(int stringLength, char * alphabet, int alphabetSize, char * text, uint32_t hash[4], int * initialPermutation, uint64_t count, char * textStartAddress, int totalStringLength)
{
	// pouzit uint32_t
	uint32_t hashPlaceHolderNew[4];
	for (int i = 0; i < stringLength; i++)
	{
		// nastaveni stringu do pocatecniho stavu
		text[i] = alphabet[initialPermutation[i]];
	}
	text[stringLength] = 0;
	bool overflow = false;
	double localCount = 0;
	bool retTmp = false;

	while (!overflow)
	{
		md5(textStartAddress, totalStringLength, hashPlaceHolderNew);
		isHashEqualNew(hashPlaceHolderNew, hash, &retTmp);
		if (retTmp)
		{
			//free(hashedString);
			return textStartAddress;
		}
		initialPermutation[0]++;
		initialPermutation[0] %= alphabetSize;
		text[0] = alphabet[initialPermutation[0]];
		if (initialPermutation[0] == 0)
		{
			for (int i = 1; i < stringLength; i++)
			{
				// carry chain
				initialPermutation[i]++;
				initialPermutation[i] %= alphabetSize;
				text[i] = alphabet[initialPermutation[i]];
				if (initialPermutation[i] != 0)
					break;
				else
					if (i == stringLength)
						overflow = true;
			}
		}

		localCount++;
		if (localCount >= count)
			break;
	}
	// hash nenalezen
	return NULL;
}

void bruteForceStepOMP(int stringLength, char * alphabet, int alphabetSize, char * text, uint32_t hash[4], uint64_t count)
{
	// pouzit uint32_t
	
	uint64_t countPerThread = ceil((double)count / cores);
	uint32_t hashPlaceHolderNew[4];
#pragma omp parallel private(hashPlaceHolderNew)
	{
#pragma omp for schedule(dynamic) 

		for (int c = 0; c < cores; c++)
		{
			int ID = omp_get_thread_num();
			
			uint64_t start = ID * countPerThread;
			int * initialPermutation = (int*)malloc(stringLength * sizeof(int));
			for (int i = 0; i < stringLength; i++)
			{
				initialPermutation[i] = start % alphabetSize;
				start /= alphabetSize;
			}
			char * textLocal = (char*)malloc((stringLength + 1) * sizeof(char));
			for (int i = 0; i < stringLength; i++)
			{
				// nastaveni stringu do pocatecniho stavu
				textLocal[i] = alphabet[initialPermutation[i]];
			}
			textLocal[stringLength] = 0;
			bool overflow = false;
			double localCount = 0;
			bool retTmp = false;
			int counter = 0; 
			while (!overflow)
			{
				if (counter > OMP_THRESHOLD)
				{
					if (found)
						break;
					counter = 0; 
				}
				md5(textLocal, stringLength, hashPlaceHolderNew);
				isHashEqualNew(hashPlaceHolderNew, hash, &retTmp);
				if (retTmp)
				{
					memcpy(text, textLocal, stringLength + 1);
					free(textLocal);
					found = true;
					break;
					
				}
				initialPermutation[0]++;
				initialPermutation[0] %= alphabetSize;
				textLocal[0] = alphabet[initialPermutation[0]];
				if (initialPermutation[0] == 0)
				{
					for (int i = 1; i < stringLength; i++)
					{
						// carry chain
						initialPermutation[i]++;
						initialPermutation[i] %= alphabetSize;
						textLocal[i] = alphabet[initialPermutation[i]];
						if (initialPermutation[i] != 0)
							break;
						else
							if (i == stringLength)
								overflow = true;
					}
				}

				localCount++;
				counter++; 
				if (localCount >= countPerThread)
					break;

			}
			
		}

	}
}


char * bruteForceNew(int minLength, int maxLength, char * alphabet, int alphabetSize, uint32_t hash[4])
{
	for (int i = minLength; i <= maxLength; i++)
	{
		char * text = (char *)malloc((i + 1) * sizeof(char));
		//char * value = bruteForceStepRec(0, i, alphabet, alphabetSize, text, hash);
		int * initialPermutation = (int*)calloc(sizeof(int), i);
		uint64_t count = pow(alphabetSize, i);
		bruteForceStepOMP(i, alphabet, alphabetSize, text, hash, count); 

		if (found)
			return text;
		free(text); 
	}

	return NULL;
}

char * subCharacter(char * word, char * begin, int len, uint32_t hash[4])
{
	uint32_t hashPlaceholder[4];
	bool retTmp = false;
	if (*begin != 0)
	{
		for (int i = 0; i < charToSubsCount; i++)
		{
			if (*begin == charToSubs[i])
			{
				char backup = *begin;
				*begin = subsChar[i];
				// recursion w/ substitute char
				char * ret = subCharacter(word, begin + 1, len, hash);
				if (ret != NULL)
					return ret;
				*begin = backup;
			}

		}

		char * ret = subCharacter(word, begin + 1, len, hash);
		return ret;

	}
	/*
	while (*begin != 0)
	{
	for (int i = 0; i < charToSubsCount; i++)
	{
	if (*begin == charToSubs[i])
	{
	char backup = *begin;
	*begin = subsChar[i];
	// recursion w/ substitute char
	subCharacter(word, begin + 1, len, hash);
	*begin = backup;
	// recursion w/out substitute char
	subCharacter(word, begin + 1, len, hash);
	}
	}
	begin++;
	}
	*/
	else {
		md5(word, len, hashPlaceholder);
		isHashEqualNew(hashPlaceholder, hash, &retTmp);
		if (retTmp)
		{
			return word;
		}
		return NULL;
	}
}

// Rozsireny slovnikovy utok, aplikuje pouze pravidla pridavani pismen v rozsahu minLength - maxLength za slovo, v budoucnu lze upravovat pomoci rules
void dictionaryAttackOMP(char * dictionaryFile, uint32_t hash[4], char ** alphabet, int * alphabetSize, int * minLength, int * maxLength, int * rules, int rulesCount, char * text)
{
	uint32_t hashPlaceholder[4];

	FILE * fp = fopen(dictionaryFile, "r");

	bool retTmp = false;
	bool end = false;
	// alocate memory for dictionary words
	char ** words = (char**)malloc(OMP_WORDS_PER_CORE * cores * sizeof(char*));
	for (int i = 0; i < OMP_WORDS_PER_CORE * cores; i++)
	{
		words[i] = (char*)malloc(OMP_MAX_WORD_LEN + 30 * sizeof(char));
	}
	int maxLen = 0;
	if (fp == NULL)
	{
		printf("Cant open the dictionary");
		return;
	}
	char * word = (char*)malloc(255);
	while (true)
	{
		uint64_t read;
		for (read = 0; read < OMP_WORDS_PER_CORE * cores; read++)
		{
			if (fscanf(fp, "%256s", words[read]) == EOF)
			{
				end = true;
				break;
			}
		}

#pragma omp parallel private(hashPlaceholder)
		{
#pragma omp for schedule(dynamic) 
			for (int r = 0; r < read; r++)
			{
				if (found)
					continue;
				int len = strlen(words[r]);
				if (!rules2)
				{
					md5(words[r], len, hashPlaceholder);
					isHashEqualNew(hashPlaceholder, hash, &retTmp);
					if (retTmp)
					{
						memcpy(text, words[r], len + 1);
						found = true;
						//break;
					}
				}

				for (int i = 0; i < rulesCount; i++)
				{
					if (rules[i] == ADD_BACK)
					{
						for (int j = minLength[i]; j <= maxLength[i]; j++)
						{
							char * editStart = words[r] + len;
							int finalLength = len + j;
							editStart[j] = 0; // vynulovat konec stringu
							int * initialPermutation = (int*)calloc(j, sizeof(int));
							uint64_t count = pow(alphabetSize[i], j);
							char * result = bruteForceStepNew(j, alphabet[i], alphabetSize[i], editStart, hash, initialPermutation, count, words[r], finalLength);
							if (result != NULL)
							{
								memcpy(text, result, finalLength + 1);
								found = true;
								break;
							}
							// free(initialPermutation); 
						}
					}
					else if (rules[i] == SUBSTITUTE)
					{
						char * ret = subCharacter(words[r], words[r], len, hash);
						if (ret != NULL)
						{
							memcpy(text, ret, len);
							text[len] = 0; 
							found = true;
							break;
						}
					}
				}

			}
		}
		
		if (found)
			break; 
		if (end)
			break; 
	}
	

	fclose(fp);
}

// Rozsireny slovnikovy utok, aplikuje pouze pravidla pridavani pismen v rozsahu minLength - maxLength za slovo, v budoucnu lze upravovat pomoci rules
char * dictionaryAttack(char * dictionaryFile, uint32_t hash[4], char ** alphabet, int * alphabetSize, int * minLength, int * maxLength, int * rules, int rulesCount)
{
	uint32_t hashPlaceholder[4];
	FILE * fp = fopen(dictionaryFile, "r");
	bool retTmp = false;
	int maxLen = 0;
	if (fp == NULL)
	{
		printf("Cant open the dictionary");
		return NULL;
	}
	char * word = (char*)malloc(255);
	while (true)
	{

		if (fscanf(fp, "%s", word) == EOF)
			break;
		int len = strlen(word);
		maxLen = MAX(maxLen, len);
		if (!rules2)
		{
			md5(word, len, hashPlaceholder);
			isHashEqualNew(hashPlaceholder, hash, &retTmp);
			if (retTmp)
			{
				//free(hashedString);
				fclose(fp);
				return word;
			}
		}

		for (int i = 0; i < rulesCount; i++)
		{
			if (rules[i] == ADD_BACK)
			{
				for (int j = minLength[i]; j <= maxLength[i]; j++)
				{
					char * editStart = word + len;
					int finalLength = len + j;
					editStart[j] = 0; // vynulovat konec stringu
					int * initialPermutation = (int*)calloc(j, sizeof(int));
					uint64_t count = pow(alphabetSize[i], j);
					char * result = bruteForceStepNew(j, alphabet[i], alphabetSize[i], editStart, hash, initialPermutation, count, word, finalLength);
					if (result != NULL)
					{
						fclose(fp);
						return word;
					}
					// free(initialPermutation); 
				}
			}
			else if (rules[i] == SUBSTITUTE)
			{
				char * ret = subCharacter(word, word, len, hash);
				if (ret != NULL)
				{
					fclose(fp);
					return ret;
				}
			}
		}
	}

	free(word);
	fclose(fp);
	return NULL;
}


void badUsage()
{
	printf("Usage: PATH_TO_PROGRAM mode [path_to_dictionary | alphabet] hash [min_length] [max_length]\n\n");
	printf("MODE:\n");
	printf("0 - Dictionary attack\n");
	printf("    Usage: PATH_TO_PROGRAM 0 path_to_dictionary hash {0-%d}[[rule] [alphabet] [min_length] [max_length]] cores\n", MAX_RULES_COUNT);
	printf("1 - Brute-force attack\n");
	printf("    Usage: PATH_TO_PROGRAM 1 alphabet hash min_length max_length cores\n");
	printf("2 - Brute-force attack GPU\n");
	printf("    Usage: PATH_TO_PROGRAM 1 alphabet hash min_length max_length blocks threads\n");
	printf("3 - Dictionary attack - GPU\n");
	printf("    Usage: PATH_TO_PROGRAM 0 path_to_dictionary hash {0-%d}[[rule] [alphabet] [min_length] [max_length]] blocks threads\n", MAX_RULES_COUNT);
	printf("ALPHABET:\n");
	printf("0 - numbers only\n");
	printf("1 - lower case\n");
	printf("2 - upper case\n");
	printf("3 - lower+upper case\n");
	printf("4 - lower+upper case + numbers\n");
	printf("5 - all characters\n");

}



uint32_t * stringToHashNew(char * hashString)
{
	uint8_t * hashArray = (uint8_t *)malloc(16 * sizeof(uint8_t));
	uint32_t * hashNew = (uint32_t *)calloc(4, sizeof(uint32_t));
	for (int i = 0; i < 16; i++)
	{
		uint8_t hiNibble = (uint8_t)tolower(hashString[2 * i]);
		hiNibble > 57 ? hiNibble -= 87 : hiNibble -= 48;
		uint8_t loNibble = (uint8_t)tolower(hashString[2 * i + 1]);
		loNibble > 57 ? loNibble -= 87 : loNibble -= 48;
		hashArray[i] = hiNibble << 4 | loNibble;
	}
	for (int i = 0; i < 16; i++)
	{
		uint32_t tmp = hashArray[i] << ((i % 4) * 8);
		hashNew[i / 4] |= tmp;
	}
	free(hashArray);
	return hashNew;
}



#pragma endregion CPU

int main(int argc, char *argv[])
{
	// args 1 0 52c69e3a57331081823331c4e69d3f2e 6 6 (999999)
	// 0 E:\\Dictionary\slovnik.txt 1b34d880de0281139ed8d526b9462e9d 1 1 1 3
	// 0 E:\\Dictionary\slovnik.txt 1b34d880de0281139ed8d526b9462e9d 2 2 ss 5$
	// 0 E:\\words.txt 77360f71a0c28c212111a617b90466d8 0 1 1 3
	// 3 E:\\Dictionary\slovnik.txt b8074d446492705a6dd7d5e75aaf954f 1 0 1 1 32 128
	// 0 E:\\Dictionary\slovnik.txt 5f4dcc3b5aa765d61d8327deb882cf99 2

	uint32_t *hash;
	char *originalString = NULL;
	char word[OMP_MAX_WORD_LEN + 50];
	int mode = -1;
	int alphabetMode = -1;
	char *_alphabet;
	int alphabetLen;

	if (argc < 4) {
		badUsage();
		return -1;
	}

	mode = atoi(argv[1]);
	hash = stringToHashNew(argv[3]);

	if (mode == 0 || mode == 3) {
		//	printf("    Usage: PATH_TO_PROGRAM 0 path_to_dictionary hash {0-%d}[[rule] [alphabet] [min_length] [max_length]]\n", MAX_RULES_COUNT);
		char * alphabet[MAX_RULES_COUNT];
		int alphabetSize[MAX_RULES_COUNT];
		int minLength[MAX_RULES_COUNT];
		int maxLength[MAX_RULES_COUNT];
		int rules[MAX_RULES_COUNT];
		int rulesCount = 0;
		if (argc > 4)
		{
			int argcTmp = argc;
			if (mode == 3)
				argcTmp -= 2;
			else
				--argcTmp; 
			if (argcTmp % 4 == 0)
			{

				for (int i = 4; i < argcTmp; i += 4)
				{
					if (rulesCount + 1 == MAX_RULES_COUNT)
					{
						printf("Too many rules\n");
						break;
					}
					rules[rulesCount] = atoi(argv[i]);
					if (rules[rulesCount] == ADD_BACK)
					{
						alphabetMode = atoi(argv[i + 1]);
						if (alphabetMode >= 0 && alphabetMode <= 5) {
							alphabet[rulesCount] = alph[alphabetMode];
							alphabetSize[rulesCount] = sizes[alphabetMode];
						}

						else
						{
							printf("Incorrectly defined dictionary rules - ignore all\n");
							rulesCount = 0;
							break;
						}
						minLength[rulesCount] = atoi(argv[i + 2]);
						maxLength[rulesCount] = atoi(argv[i + 3]);
						rulesCount++;
					}
					else if (rules[rulesCount] == SUBSTITUTE)
					{

						int subCount = atoi(argv[i + 1]);
						charToSubsCount = (size_t)subCount;
						charToSubs = (char*)malloc(subCount * sizeof(char));
						subsChar = (char*)malloc(subCount * sizeof(char));
						for (int j = 0; j < subCount; j++)
						{
							charToSubs[j] = argv[i + 2][j];
							subsChar[j] = argv[i + 3][j];
						}
						rulesCount++;
						rules2 = true; 
					}
				}
			}
			else
				printf("Incorrectly defined dictionary rules - ignore all\n");
		}
		if (mode == 0)
		{
			cores = atoi(argv[rulesCount * 4 + 4]);
			if (cores <= 0)
			{
				printf("invalid core count, setting core count to 1"); 
				cores = 1;
			}
			omp_set_num_threads(cores);
			if (cores == 1)
				originalString = dictionaryAttack(argv[2], hash, alphabet, alphabetSize, minLength, maxLength, rules, rulesCount); 
			else
			{
				dictionaryAttackOMP(argv[2], hash, alphabet, alphabetSize, minLength, maxLength, rules, rulesCount, word); 
				if (found)
				{
					originalString = word; 
				}
			}
		}
		else if (mode == 3)
		{
			printf("NOT IMPLEMENTED\n");
			return -1;
			/*
			if (argc < rulesCount * 4 + 6)
			{
			badUsage();
			return -1;
			}
			blocks = atoi(argv[rulesCount * 4 + 4]);
			threads = atoi(argv[rulesCount * 4 + 5]);
			originalString = cudaDictionaryAttack(argv[2], hash, alphabet, alphabetSize, minLength, maxLength, rules, rulesCount);
			*/
		}
		if (originalString == NULL) {
			printf("No matches!\n");
			return 0;
		}
		else if (originalString[0] == '0')
		{
			printf("No matches!\n");
			return 0;
		}
		else {
			printf("%s\n", originalString);
			return 0;
		}


	}
	if (mode == 1) {
		if (argc < 7) {
			badUsage();
			return -1;
		}

		int minLenght = -1, maxLength = -1;
		alphabetMode = atoi(argv[2]);
		minLenght = atoi(argv[4]);
		maxLength = atoi(argv[5]);
		cores = atoi(argv[6]); 
		omp_set_num_threads(cores);
		if (minLenght > maxLength) {
			printf("Minimum length must be less than or equal to the maximum length.\n");
			return -1;
		}

		if (alphabetMode >= 0 && alphabetMode <= 5) {
			_alphabet = alph[alphabetMode];
			alphabetLen = sizes[alphabetMode];
		}
		else {
			badUsage();
			return -1;
		}

		if (maxLength > limits[alphabetMode])
		{
			printf("Max length for this aplhabet mode is %d\n", limits[alphabetMode]); 
			return -1; 
		}

		//originalString = cudaBruteForceStart(minLenght, maxLength, _alphabet, alphabetLen, hash);
		originalString = bruteForceNew(minLenght, maxLength, _alphabet, alphabetLen, hash);
		if (originalString == NULL) {
			printf("No matches!\n");
			return 0;
		}
		else {
			printf("%s\n", originalString);
			return 0;
		}

	}
	else if (mode == 2)
	{
		printf("NOT IMPLEMENTED\n");
		return -1;
		/*
		if (argc < 8) {
		badUsage();
		return -1;
		}

		int minLenght = -1, maxLength = -1;
		alphabetMode = atoi(argv[2]);
		minLenght = atoi(argv[4]);
		maxLength = atoi(argv[5]);
		blocks = atoi(argv[6]);
		threads = atoi(argv[7]);

		if (minLenght > maxLength) {
		printf("Minimum length must be less than or equal to the maximum length.\n");
		return -1;
		}

		if (alphabetMode >= 0 && alphabetMode <= 5) {
		_alphabet = alph[alphabetMode];
		alphabetLen = sizes[alphabetMode];
		}
		else {
		badUsage();
		return -1;
		}

		originalString = cudaBruteForceStart(minLenght, maxLength, _alphabet, alphabetLen, hash);
		//originalString = bruteForceNew(minLenght, maxLength, _alphabet, alphabetLen, hash);
		if (originalString[0] == 0) {
		printf("No matches!\n");
		return 0;
		}
		else {
		printf("%s\n", originalString);
		return 0;
		}
		*/
	}
	return 0;
}


