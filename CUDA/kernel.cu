#define _CRT_SECURE_NO_WARNINGS
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include "md5.c"

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <ctype.h>
#include <math.h>


static void HandleError(cudaError_t err,
	const char *file,
	int line) {
	if (err != cudaSuccess) {
		printf("%s in %s at line %d\n", cudaGetErrorString(err),
			file, line);
		exit(EXIT_FAILURE);
	}
}
#define HANDLE_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ))

#define THREADS 128 /// 128
#define BLOCKS 32 /// 32

#define THRESHOLD 1000
#define DICTIONARY_THRESHOLD 250
#define MAX_ALPHABET_SIZE 95
#define MAX_RULES_COUNT 5

#define MAX_WORD_LENGTH 200
#define GRANULARITY 5000
#define MEMORY_RATIO 2



#define ADD_BACK 1

#define DEVICE 0 // toto mozna bude nutne menit na STARU!

char tnumbers[11] = "0123456789";
char tlowercase[27] = "abcdefghijklmnopqrstuvwxyz";
char tuppercase[27] = "ABCDEFGHIJKLMNOPQRTSUVWXYZ";
char tlowerupper[53] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRTSUVWXYZ";
char tloweruppernums[63] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRTSUVWXYZ0123456789";
char allchars[95] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRTSUVWXYZ0123456789!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
char * alph[6] = { &tnumbers[0], &tlowercase[0], &tuppercase[0], &tlowerupper[0], &tloweruppernums[0], allchars };
char sizes[6] = { 10, 26, 26, 52, 62, 94 };
int limits[6] = { 19, 13, 13, 11, 10, 9 }; // max word length

char * valuePlaceholder;

__constant__ char alphabetGPU[MAX_ALPHABET_SIZE];
__constant__ uint32_t hashGPU[4]; 

__constant__ char dictionaryAlphabetGPU[MAX_RULES_COUNT * MAX_ALPHABET_SIZE];
__constant__ int dictionarySizeGPU[MAX_RULES_COUNT];
__constant__ int minLengthGPU[MAX_RULES_COUNT];
__constant__ int maxLengthGPU[MAX_RULES_COUNT];
__constant__ int rulesGPU[MAX_RULES_COUNT];

int threads = THREADS;
int blocks = BLOCKS; 


#pragma region GPU
__device__ void isHashEqualNewDevice(uint32_t * hash1, uint32_t * hash2, bool * ret)
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

#pragma region Brute force
__device__ void * bruteForceStepDevice(int stringLength, int alphabetSize, char * alphabet, char * text, int * initialPermutation, uint64_t count, char * valuePlaceholder, char * textStartAddress, int totalStringLength)
{
	// pouzit uint32_t

	uint32_t hashPlaceHolderNew[4];

	uint32_t hashLocal[4]; 
	memcpy(hashLocal, hashGPU, 4 * sizeof(uint32_t));
	for (int i = 0; i < stringLength; i++)
	{
		// nastaveni stringu do pocatecniho stavu
		text[i] = alphabet[initialPermutation[i]];
	}


	text[stringLength] = 0;
	bool overflow = false;
	uint64_t localCount = 0;
	bool retTmp = false;
	uint8_t msg[200]; 
	while (!overflow)
	{
		//printf("Zkousim %s\n", textStartAddress); 
		md5Device(textStartAddress, totalStringLength, hashPlaceHolderNew, msg);
		isHashEqualNewDevice(hashPlaceHolderNew, hashLocal, &retTmp);
		if (retTmp)
		{
			memcpy(valuePlaceholder, textStartAddress, totalStringLength * sizeof(char));
			//free(hashedString);
			return; 
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
		if (localCount % THRESHOLD == 0)
		{
			if (valuePlaceholder[0] != 0)
				return; 
		}
	}
	// hash nenalezen
	return NULL;
}

__global__ void bruteForceDevice(int len, uint64_t total, int alphabetSize, char * valuePlaceholder)
{
	cudaError_t cudaStatus;
	char * text;
	int * initialPermutation; 
	int threadCount = blockDim.x;
	int blockCount = gridDim.x;
	double tmp = ((double)total / blockCount);
	uint64_t blockWork = (uint64_t)ceil(tmp);
	tmp = (double)total / (blockCount*threadCount);
	uint64_t threadWork = (uint64_t)ceil(tmp);
	uint64_t start = blockIdx.x * blockWork + threadIdx.x * threadWork;
	

	text = (char*)malloc(len + 1); 

	if (text == 0)
	{
		printf("bruteForceDevice, nelze alokovat pamet pro text\n");
		return;
	}

	initialPermutation = (int*)malloc(len * sizeof(int));
	if (initialPermutation == NULL) {
		printf("bruteForceDevice, nelze alokovat pamet\n");
		return;
	}
	

	for (int i = 0; i < len; i++)
	{

		initialPermutation[i] = start % alphabetSize;
		start /= alphabetSize; 
	}
	bruteForceStepDevice(len, alphabetSize, alphabetGPU, text, initialPermutation, threadWork, valuePlaceholder, text, len);

	free(text);
	free(initialPermutation);
}

__host__ char * cudaBruteForceStart(int minLength, int maxLength, char * alphabet, int alphabetSize, uint32_t hash[4])
{
	cudaError_t cudaStatus;
	char * originalValue = NULL;
	HANDLE_ERROR(cudaMemcpyToSymbol((const void *)alphabetGPU, alphabet, alphabetSize, 0, cudaMemcpyHostToDevice));
	HANDLE_ERROR(cudaMemcpyToSymbol((const void *)hashGPU, hash, sizeof(uint32_t) * 4, 0, cudaMemcpyHostToDevice));

	for (int i = minLength; i <= maxLength; i++)
	{
		originalValue = NULL; 
		HANDLE_ERROR(cudaMalloc((void**)&valuePlaceholder, (size_t)(i * sizeof(char) + 1)));

		HANDLE_ERROR(cudaMemset(valuePlaceholder, 0, (size_t)i + 1));
		uint64_t total = pow(alphabetSize, i);
		bruteForceDevice << <blocks, threads >> >(i, total, alphabetSize, valuePlaceholder);
		originalValue = (char *)malloc(i * sizeof(char) + 1);
		cudaDeviceSynchronize();

		HANDLE_ERROR(cudaMemcpy(originalValue, valuePlaceholder, i, cudaMemcpyDeviceToHost));
		HANDLE_ERROR(cudaFree(valuePlaceholder));

		if (originalValue[0] != 0)
		{
			originalValue[i] = 0; 
			break;
		}

		free(originalValue);
	}
	return originalValue; 
}

#pragma endregion Brute force

// memlimits in bytes!!!
__host__ char * prepareWords(FILE * fp, size_t memLimit, unsigned int * count, int * maxLen, bool * eof)
{
	long start = ftell(fp); 

	register int _maxLen = 0;
	register unsigned int _count = 0;
	char bigbuffer[5000];
	char word[MAX_WORD_LENGTH];
	bool _eof = false; 
	int index = 0; 
	while (true)
	{
		for (int i = 0; i < GRANULARITY; i++)
		{
			if (fscanf(fp, "%s", bigbuffer) == EOF)
			{
				_eof = true;
				break; 
			}
			int tmp = strlen(bigbuffer);
			if (tmp > MAX_WORD_LENGTH)
				continue; 
			_maxLen = max(tmp, _maxLen); 
			_count++; 
			index++; 
		}
		_maxLen += 2;
		size_t tmp = _maxLen * _count * sizeof(char); 
		if (tmp > memLimit)
		{
			_count -= index;
			break; 
		}
		if (_count > UINT_MAX - 2 * GRANULARITY)
			break; 
		if (_eof)
			break; 
		index = 0; 
	}

	*eof = _eof; 
	fseek(fp, start, SEEK_SET); 
	long tmp = ftell(fp); 
	char * words = (char*)malloc(_count * _maxLen * sizeof(char));
	for (unsigned int i = 0; i < _count; i++)
	{ 
		fscanf(fp, "%s", words + i*_maxLen);
		words[(i + 1)*_maxLen - 1] = (char)strlen(words + i*_maxLen);
	}

	*count = _count;
	*maxLen = _maxLen;
	return words; 


	
}

__global__ void DictionaryAttackStep(unsigned int count, char * words, char * valuePlaceholder, int maxLen, int rulesCount)
{
	int threadCount = blockDim.x;
	int blockCount = gridDim.x;
	char word[MAX_WORD_LENGTH + 40]; 
	uint8_t msg[300];
	uint32_t hashPlaceHolderNew[4];
	int initialPermutation[25]; 

	bool retTmp = false; 

	cudaError_t cudaStatus;
	uint32_t hashLocal[4];
	memcpy(hashLocal, hashGPU, 4 * sizeof(uint32_t));

	double tmp = ((double)count / blockCount);
	uint64_t blockWork = (uint64_t)ceil(tmp);
	tmp = (double)count / (blockCount*threadCount);
	uint64_t threadWork = (uint64_t)ceil(tmp);

	int start = blockIdx.x * blockWork + threadIdx.x * threadWork;
	int end = start + threadWork;
	char * address = words + start*maxLen;
	char * endAddress = words + end*maxLen; 
	char * realEndAddress = words + count * maxLen; 

	endAddress > realEndAddress ? endAddress = realEndAddress : endAddress = endAddress; 
	for (int i = 0; address < endAddress; address += maxLen, i++)
	{
		void * destination = memcpy(word, address, maxLen);
		size_t len = (size_t)((unsigned char)word[maxLen - 1]);
		md5Device(word, len, hashPlaceHolderNew, msg);
		isHashEqualNewDevice(hashPlaceHolderNew, hashLocal, &retTmp);
		if (retTmp)
		{
			memcpy(valuePlaceholder, word, len + 1);
			//free(hashedString);
			return;
		}
		for (int j = 0; j < rulesCount; j++)
		{
			if (rulesGPU[j] == ADD_BACK)
			{
				for (int k = minLengthGPU[j]; k <= maxLengthGPU[j]; k++)
				{
					char * editStart = word + len;
					int finalLength = len + k;
					editStart[k] = 0; // vynulovat konec stringu
					for (int l = 0; l < k; l++)
					{
						initialPermutation[l] = 0; 
					}
					uint64_t count = (uint64_t)pow((double)dictionarySizeGPU[j], (double)k);
					//printf("%ddsdsdsd %c\n", count, dictionaryAlphabetGPU[5]);
					bruteForceStepDevice(k, dictionarySizeGPU[j], dictionaryAlphabetGPU + j*MAX_ALPHABET_SIZE, editStart, initialPermutation, count , valuePlaceholder, word, finalLength);

				}
			}
		}

		if (i == DICTIONARY_THRESHOLD)
		{
			if (valuePlaceholder[0] != 0)
				return;
			i = 0; 
		}

	}

}

__host__ char * cudaDictionaryAttack(char * dictionaryFile, uint32_t hash[4], char ** alphabet, int * alphabetSize, int * minLength, int * maxLength, int * rules, int rulesCount)
{

	// GPU MEMORY:
	char * usedMemory, *tmpMemory;
	char * originalValue = NULL;
	bool retTmp = false;
	char word[MAX_WORD_LENGTH]; 
	bool eof = false; ;
	int maxLen = -1, lastLen;
	unsigned int count = 0, last_count; 
	size_t * freeMemory,*totalMemory; 
	size_t memLimit = 0;
	bool __eof = false; 
	uint64_t nacteno = 0; 

	FILE * fp = fopen(dictionaryFile, "r");
	if (fp == NULL)
	{
		printf("Cant open the dictionary");
		return NULL;
	}
	
	if (rulesCount > 0 && rulesCount <= MAX_RULES_COUNT)
	{
		int * _rules = (int *)malloc(rulesCount * sizeof(int));
		int * _alphabetSize = (int *)malloc(rulesCount * sizeof(int));
		int * _minLength = (int *)malloc(rulesCount * sizeof(int));
		int * _maxLength = (int *)malloc(rulesCount * sizeof(int));
		char * _alphabet = (char *)malloc(rulesCount * MAX_ALPHABET_SIZE * sizeof(char));

		for (int i = 0; i < rulesCount; i++)
		{
			_rules[i] = rules[i];
			_alphabetSize[i] = alphabetSize[i];
			_minLength[i] = minLength[i];
			_maxLength[i] = maxLength[i];
			memcpy(_alphabet + i*MAX_ALPHABET_SIZE, alphabet[i], alphabetSize[i]);
		}
		
		HANDLE_ERROR(cudaMemcpyToSymbol(rulesGPU, _rules, rulesCount*sizeof(int), 0, cudaMemcpyHostToDevice));
		HANDLE_ERROR(cudaMemcpyToSymbol(dictionarySizeGPU, _alphabetSize, rulesCount * sizeof(int), 0, cudaMemcpyHostToDevice));
		HANDLE_ERROR(cudaMemcpyToSymbol( minLengthGPU, _minLength, rulesCount * sizeof(int), 0, cudaMemcpyHostToDevice));
		HANDLE_ERROR(cudaMemcpyToSymbol(maxLengthGPU, _maxLength, rulesCount * sizeof(int), 0, cudaMemcpyHostToDevice));
		HANDLE_ERROR(cudaMemcpyToSymbol(dictionaryAlphabetGPU, _alphabet, rulesCount * MAX_ALPHABET_SIZE * sizeof(char), 0, cudaMemcpyHostToDevice));
		free(_rules);
		free(_alphabetSize);
		free(_minLength);
		free(_maxLength);
		free(_alphabet); 
	}
	cudaDeviceProp prop; 
	HANDLE_ERROR(cudaGetDeviceProperties(&prop, DEVICE)); 
	memLimit = prop.totalGlobalMem / MEMORY_RATIO;

	char * words = prepareWords(fp, memLimit, &count, &maxLen, &__eof);
	nacteno += count; 
	HANDLE_ERROR(cudaMemcpyToSymbol((const void *)hashGPU, hash, sizeof(uint32_t) * 4, 0, cudaMemcpyHostToDevice));
	HANDLE_ERROR(cudaMalloc(&usedMemory, maxLen * count * sizeof(char))); 
	HANDLE_ERROR(cudaMemcpy(usedMemory,words, maxLen * count * sizeof(char), cudaMemcpyHostToDevice));
	free(words); 
	
	do 
	{
		eof = __eof; 
		last_count = count; 
		lastLen = maxLen;
		originalValue = (char *)malloc(maxLen * sizeof(char));
		HANDLE_ERROR(cudaMalloc((void**)&valuePlaceholder, (size_t)(maxLen * sizeof(char))));
		HANDLE_ERROR(cudaMemset(valuePlaceholder, 0, (size_t)maxLen * sizeof(char)));
		if (count == 0)
			break; 

		DictionaryAttackStep << < blocks, threads >> > (count, usedMemory, valuePlaceholder, maxLen, rulesCount); 
		// run kernel
		words = prepareWords(fp, memLimit, &count, &maxLen, &__eof);
		nacteno += count;
		if (count == 0 && !eof)
		{
			printf("Too little VRAM! Exiting now\n");
			return NULL; 
		}
		if (count > 0)
		{
			HANDLE_ERROR(cudaMalloc(&tmpMemory, maxLen * count * sizeof(char)));
			HANDLE_ERROR(cudaMemcpy(tmpMemory, words, maxLen * count * sizeof(char), cudaMemcpyHostToDevice));
			free(words);
		}
		cudaDeviceSynchronize();
		HANDLE_ERROR(cudaFree(usedMemory));
		usedMemory = tmpMemory; 

		HANDLE_ERROR(cudaMemcpy(originalValue, valuePlaceholder, lastLen, cudaMemcpyDeviceToHost));

		if (originalValue[0] != 0)
			break; 
		//free(originalValue); 
		HANDLE_ERROR(cudaFree(valuePlaceholder));
	} while (!eof); 
	
	fclose(fp); 
	if (originalValue[0] == 0)
		return NULL;
	else
		return originalValue; 
	

}

#pragma endregion GPU

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
			return text;
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

char * bruteForceNew(int minLength, int maxLength, char * alphabet, int alphabetSize, uint32_t hash[4])
{
	for (int i = minLength; i <= maxLength; i++)
	{
		char * text = (char *)malloc((i + 1) * sizeof(char));
		//char * value = bruteForceStepRec(0, i, alphabet, alphabetSize, text, hash);
		int * initialPermutation = (int*)calloc(sizeof(int), i);
		uint64_t count = pow(alphabetSize, i);
		char * value = bruteForceStepNew(i, alphabet, alphabetSize, text, hash, initialPermutation, count, text, i);
		if (value != NULL)
			return value;
		free(text);
	}

	return NULL;
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
		maxLen = max(maxLen, len); 
		md5(word, len, hashPlaceholder);
		isHashEqualNew(hashPlaceholder, hash, &retTmp);
		if (retTmp)
		{
			//free(hashedString);
			fclose(fp);
			return word;
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
	printf("    Usage: PATH_TO_PROGRAM 0 path_to_dictionary hash {0-%d}[[rule] [alphabet] [min_length] [max_length]]\n", MAX_RULES_COUNT);
	printf("1 - Brute-force attack\n");
	printf("    Usage: PATH_TO_PROGRAM 1 alphabet hash min_length max_length\n");
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
// 0 E:\\words.txt 77360f71a0c28c212111a617b90466d8 0 1 1 3
// 3 E:\\Dictionary\slovnik.txt b8074d446492705a6dd7d5e75aaf954f 1 0 1 1 32 128

	uint32_t *hash;
	char *originalString;
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
			}
			else
				printf("Incorrectly defined dictionary rules - ignore all\n");
		}
		if(mode == 0)
			originalString = dictionaryAttack(argv[2], hash, alphabet, alphabetSize, minLength, maxLength, rules, rulesCount);
		else if (mode == 3)
		{
			if (argc < rulesCount * 4 + 6)
			{
				badUsage();
				return -1; 
			}
			blocks = atoi(argv[rulesCount * 4 + 4]);
			threads = atoi(argv[rulesCount * 4 + 5]);
			originalString = cudaDictionaryAttack(argv[2], hash, alphabet, alphabetSize, minLength, maxLength, rules, rulesCount);
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
		if (argc < 6) {
			badUsage();
			return -1;
		}

		int minLenght = -1, maxLength = -1;
		alphabetMode = atoi(argv[2]);
		minLenght = atoi(argv[4]);
		maxLength = atoi(argv[5]);

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
	}
	return 0;
}


