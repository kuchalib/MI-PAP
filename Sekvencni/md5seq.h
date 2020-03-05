#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void md5(char *initial_msg, size_t initial_len, uint32_t* hash);