/**
 * sX16RT algorithm (X16 with Randomized chain order based on time)
 *
 * tpruvot 2018 - GPL code
 * blondfrogs 2018 - TimeHash code
 */

#include <stdio.h>
#include <memory.h>
#include <unistd.h>

extern "C" {
#include "sph/sph_blake.h"
#include "sph/sph_bmw.h"
#include "sph/sph_groestl.h"
#include "sph/sph_skein.h"
#include "sph/sph_jh.h"
#include "sph/sph_keccak.h"

#include "sph/sph_luffa.h"
#include "sph/sph_cubehash.h"
#include "sph/sph_shavite.h"
#include "sph/sph_simd.h"
#include "sph/sph_echo.h"

#include "sph/sph_hamsi.h"
#include "sph/sph_fugue.h"
#include "sph/sph_shabal.h"
#include "sph/sph_whirlpool.h"
#include "sph/sph_sha2.h"
}

#include "miner.h"
#include "cuda_helper.h"
#include "cuda_x16r.h"

static uint32_t *d_hash[MAX_GPUS];

extern void quark_bmw512_cpu_hash_64_final(int thr_id, uint32_t threads, uint32_t *d_nonceVector, uint32_t *d_hash, uint32_t *resNonce, const uint64_t target);
extern void x11_luffa512_cpu_hash_64_final(int thr_id, uint32_t threads, uint32_t *d_hash, uint64_t target, uint32_t *d_resNonce);
extern void tribus_echo512_final(int thr_id, uint32_t threads, uint32_t *d_hash, uint32_t *d_resNonce, const uint64_t target);
extern void x16_simd_echo512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t *d_hash);
extern void x11_cubehash_shavite512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t *d_hash);
extern void quark_blake512_cpu_hash_64_final(int thr_id, uint32_t threads, uint32_t *d_nonceVector, uint32_t *d_outputHash, uint32_t *resNonce, const uint64_t target);
extern void x13_fugue512_cpu_hash_64_final_sp(int thr_id, uint32_t threads, uint32_t *d_hash, uint32_t *d_resNonce, const uint64_t target);
extern void x16_simd_fugue512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t *d_hash);
extern void x16_simd_hamsi512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t *d_hash);
extern void x16_simd_whirlpool512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t *d_hash);

#define TIME_MASK 0xffffff80

enum Algo {
	BLAKE = 0,
	BMW,
	GROESTL,
	JH,
	KECCAK,
	SKEIN,
	LUFFA,
	CUBEHASH,
	SHAVITE,
	SIMD,
	ECHO,
	HAMSI,
	FUGUE,
	SHABAL,
	WHIRLPOOL,
	SHA512,
	HASH_FUNC_COUNT
};

static const char* algo_strings[] = {
	"blake",
	"bmw512",
	"groestl",
	"jh512",
	"keccak",
	"skein",
	"luffa",
	"cube",
	"shavite",
	"simd",
	"echo",
	"hamsi",
	"fugue",
	"shabal",
	"whirlpool",
	"sha512",
	NULL
};

static __thread uint32_t s_ntime = UINT32_MAX;
static __thread bool s_implemented = false;
static __thread char hashOrder[HASH_FUNC_COUNT + 1] = { 0 };

static void getAlgoString(const uint32_t* timeHash, char *output)
{
	char *sptr = output;
	uint8_t* data = (uint8_t*)timeHash;

	for (uint8_t j = 0; j < HASH_FUNC_COUNT; j++) {
		uint8_t b = (15 - j) >> 1; // 16 ascii hex chars, reversed
		uint8_t algoDigit = (j & 1) ? data[b] & 0xF : data[b] >> 4;

		if (algoDigit >= 10)
			sprintf(sptr, "%c", 'A' + (algoDigit - 10));
		else
			sprintf(sptr, "%u", (uint32_t) algoDigit);
		sptr++;
	}
	*sptr = '\0';
}

static void getTimeHash(const uint32_t timeStamp, void* timeHash)
{
    int32_t maskedTime = timeStamp & TIME_MASK;

    sha256d((unsigned char*)timeHash, (const unsigned char*)&(maskedTime), sizeof(maskedTime));
}

// X16RT CPU Hash (Validation)
extern "C" void x16rt_hash(void *output, const void *input)
{
	unsigned char _ALIGN(64) hash[128];

	sph_blake512_context ctx_blake;
	sph_bmw512_context ctx_bmw;
	sph_groestl512_context ctx_groestl;
	sph_jh512_context ctx_jh;
	sph_keccak512_context ctx_keccak;
	sph_skein512_context ctx_skein;
	sph_luffa512_context ctx_luffa;
	sph_cubehash512_context ctx_cubehash;
	sph_shavite512_context ctx_shavite;
	sph_simd512_context ctx_simd;
	sph_echo512_context ctx_echo;
	sph_hamsi512_context ctx_hamsi;
	sph_fugue512_context ctx_fugue;
	sph_shabal512_context ctx_shabal;
	sph_whirlpool_context ctx_whirlpool;
	sph_sha512_context ctx_sha512;

	void *in = (void*) input;
	int size = 80;

    uint32_t *in32 = (uint32_t*) input;
    uint32_t ntime = in32[17];

    uint32_t _ALIGN(64) timeHash[8];
	getTimeHash(ntime, &timeHash);
	getAlgoString(&timeHash[0], hashOrder);

	for (int i = 0; i < 16; i++)
	{
		const char elem = hashOrder[i];
		const uint8_t algo = elem >= 'A' ? elem - 'A' + 10 : elem - '0';

		switch (algo) {
		case BLAKE:
			sph_blake512_init(&ctx_blake);
			sph_blake512(&ctx_blake, in, size);
			sph_blake512_close(&ctx_blake, hash);
			break;
		case BMW:
			sph_bmw512_init(&ctx_bmw);
			sph_bmw512(&ctx_bmw, in, size);
			sph_bmw512_close(&ctx_bmw, hash);
			break;
		case GROESTL:
			sph_groestl512_init(&ctx_groestl);
			sph_groestl512(&ctx_groestl, in, size);
			sph_groestl512_close(&ctx_groestl, hash);
			break;
		case SKEIN:
			sph_skein512_init(&ctx_skein);
			sph_skein512(&ctx_skein, in, size);
			sph_skein512_close(&ctx_skein, hash);
			break;
		case JH:
			sph_jh512_init(&ctx_jh);
			sph_jh512(&ctx_jh, in, size);
			sph_jh512_close(&ctx_jh, hash);
			break;
		case KECCAK:
			sph_keccak512_init(&ctx_keccak);
			sph_keccak512(&ctx_keccak, in, size);
			sph_keccak512_close(&ctx_keccak, hash);
			break;
		case LUFFA:
			sph_luffa512_init(&ctx_luffa);
			sph_luffa512(&ctx_luffa, in, size);
			sph_luffa512_close(&ctx_luffa, hash);
			break;
		case CUBEHASH:
			sph_cubehash512_init(&ctx_cubehash);
			sph_cubehash512(&ctx_cubehash, in, size);
			sph_cubehash512_close(&ctx_cubehash, hash);
			break;
		case SHAVITE:
			sph_shavite512_init(&ctx_shavite);
			sph_shavite512(&ctx_shavite, in, size);
			sph_shavite512_close(&ctx_shavite, hash);
			break;
		case SIMD:
			sph_simd512_init(&ctx_simd);
			sph_simd512(&ctx_simd, in, size);
			sph_simd512_close(&ctx_simd, hash);
			break;
		case ECHO:
			sph_echo512_init(&ctx_echo);
			sph_echo512(&ctx_echo, in, size);
			sph_echo512_close(&ctx_echo, hash);
			break;
		case HAMSI:
			sph_hamsi512_init(&ctx_hamsi);
			sph_hamsi512(&ctx_hamsi, in, size);
			sph_hamsi512_close(&ctx_hamsi, hash);
			break;
		case FUGUE:
			sph_fugue512_init(&ctx_fugue);
			sph_fugue512(&ctx_fugue, in, size);
			sph_fugue512_close(&ctx_fugue, hash);
			break;
		case SHABAL:
			sph_shabal512_init(&ctx_shabal);
			sph_shabal512(&ctx_shabal, in, size);
			sph_shabal512_close(&ctx_shabal, hash);
			break;
		case WHIRLPOOL:
			sph_whirlpool_init(&ctx_whirlpool);
			sph_whirlpool(&ctx_whirlpool, in, size);
			sph_whirlpool_close(&ctx_whirlpool, hash);
			break;
		case SHA512:
			sph_sha512_init(&ctx_sha512);
			sph_sha512(&ctx_sha512,(const void*) in, size);
			sph_sha512_close(&ctx_sha512,(void*) hash);
			break;
		}
		in = (void*) hash;
		size = 64;
	}
	memcpy(output, hash, 32);
}

static bool init[MAX_GPUS] = { 0 };

//#define _DEBUG
#define _DEBUG_PREFIX "x16rt-"
#include "cuda_debug.cuh"

// #define GPU_HASH_CHECK_LOG

#ifdef GPU_HASH_CHECK_LOG
	static int algo80_tests[HASH_FUNC_COUNT] = { 0 };
	static int algo64_tests[HASH_FUNC_COUNT] = { 0 };
#endif
static int algo80_fails[HASH_FUNC_COUNT] = { 0 };

extern "C" int scanhash_x16rt(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done)
{
	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;
	const uint32_t first_nonce = pdata[19];
	const int dev_id = device_map[thr_id];
	int intensity = (device_sm[dev_id] > 500 && !is_windows()) ? 20 : 19;
	if (strstr(device_name[dev_id], "GTX 1080")) intensity = 19;
	uint32_t throughput = cuda_default_throughput(thr_id, 1U << intensity);

	if (!init[thr_id])
	{
		cudaSetDevice(device_map[thr_id]);
		if (opt_cudaschedule == -1 && gpu_threads == 1) {
			cudaDeviceReset();
			// reduce cpu usage
			cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
		}
		gpulog(LOG_INFO, thr_id, "Intensity set to %g, %u cuda threads", throughput2intensity(throughput), throughput);

		//quark_blake512_cpu_init(thr_id, throughput); // Redundant
		//quark_bmw512_cpu_init(thr_id, throughput); // Redundant
		quark_groestl512_cpu_init(thr_id, throughput);
		//quark_skein512_cpu_init(thr_id, throughput); // Redundant
		//quark_jh512_cpu_init(thr_id, throughput); // Redundant
		quark_keccak512_cpu_init(thr_id, throughput);
		x11_shavite512_cpu_init(thr_id, throughput);
		x11_simd512_cpu_init(thr_id, throughput); // 64
		x13_hamsi512_cpu_init(thr_id, throughput);
                x16_echo512_cuda_init(thr_id, throughput);
		x16_fugue512_cpu_init(thr_id, throughput);
		x15_whirlpool_cpu_init(thr_id, throughput, 0);
		x16_whirlpool512_init(thr_id, throughput);
//		x17_sha512_cpu_init(thr_id, throughput);

		CUDA_CALL_OR_RET_X(cudaMalloc(&d_hash[thr_id], (size_t) 64 * throughput), 0);

		cuda_check_cpu_init(thr_id, throughput);

		init[thr_id] = true;
	}

	if (opt_benchmark) {
		((uint32_t*)ptarget)[7] = 0x003f;
		((uint32_t*)pdata)[1] = 0xEFCDAB89;
		((uint32_t*)pdata)[2] = 0x67452301;
	}
	uint32_t _ALIGN(64) endiandata[20];

	for (int k=0; k < 19; k++)
		be32enc(&endiandata[k], pdata[k]);

    uint32_t _ALIGN(64) timeHash[8];

	uint32_t ntime = swab32(pdata[17]);
	if (s_ntime != ntime) {
	    getTimeHash(ntime, &timeHash);
		getAlgoString(&timeHash[0], hashOrder);
		s_ntime = ntime;
		s_implemented = true;
		if (!thr_id) applog(LOG_INFO, "hash order: %s time: (%08x) time hash: (%08x)", hashOrder, ntime, timeHash);
	}

	if (!s_implemented) {
		sleep(1);
		return -1;
	}

	cuda_check_cpu_setTarget(ptarget);

	char elem = hashOrder[0];
	const uint8_t algo80 = elem >= 'A' ? elem - 'A' + 10 : elem - '0';

//    applog(LOG_INFO, "version: %d", endiandata[0]);
//    applog(LOG_INFO, "prevblockhash: %08x%08x%08x%08x%08x%08x%08x%08x",endiandata[8],endiandata[7],endiandata[6],endiandata[5],endiandata[4],endiandata[3],endiandata[2],endiandata[1]);
//    applog(LOG_INFO, "veildatahash: %08x%08x%08x%08x%08x%08x%08x%08x",endiandata[16],endiandata[15],endiandata[14],endiandata[13],endiandata[12],endiandata[11],endiandata[10],endiandata[9]);
//	applog(LOG_INFO, "nTime: %d",endiandata[17]);
//	applog(LOG_INFO, "nbits: %08x",endiandata[18]);
//	applog(LOG_INFO, "nonce: %d",endiandata[19]);

	switch (algo80) {
		case BLAKE:
			quark_blake512_cpu_setBlock_80(thr_id, endiandata);
			break;
		case BMW:
			quark_bmw512_cpu_setBlock_80(endiandata);
			break;
		case GROESTL:
			groestl512_setBlock_80(thr_id, endiandata);
			break;
		case JH:
			jh512_setBlock_80(thr_id, endiandata);
			break;
		case KECCAK:
			keccak512_setBlock_80(thr_id, endiandata);
			break;
		case SKEIN:
			skein512_cpu_setBlock_80((void*)endiandata);
			break;
		case LUFFA:
			qubit_luffa512_cpu_setBlock_80_alexis((void*)endiandata);
			break;
		case CUBEHASH:
			cubehash512_setBlock_80(thr_id, endiandata);
			break;
		case SHAVITE:
			x11_shavite512_setBlock_80((void*)endiandata);
			break;
		case SIMD:
			x16_simd512_setBlock_80((void*)endiandata);
			break;
		case ECHO:
			x16_echo512_setBlock_80((void*)endiandata);
			break;
		case HAMSI:
			x16_hamsi512_setBlock_80((uint64_t*)endiandata);
			break;
		case FUGUE:
			x16_fugue512_setBlock_80((void*)pdata);
			break;
		case SHABAL:
			x16_shabal512_setBlock_80((void*)endiandata);
			break;
		case WHIRLPOOL:
			x16_whirlpool512_setBlock_80((void*)endiandata);
			break;
		case SHA512:
			x16_sha512_setBlock_80(endiandata);
			break;
		default: {
			if (!thr_id)
				applog(LOG_WARNING, "kernel %s %c unimplemented, order %s", algo_strings[algo80], elem, hashOrder);
			s_implemented = false;
			sleep(5);
			return -1;
		}
	}

	int warn = 0;

	do {
		int order = 0;

		// Hash with CUDA


		switch (algo80) {
			case BLAKE:
				quark_blake512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("blake80:");
				break;
			case BMW:
				quark_bmw512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				TRACE("bmw80  :");
				break;
			case GROESTL:
				groestl512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("grstl80:");
				break;
			case JH:
				jh512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("jh51280:");
				break;
			case KECCAK:
				keccak512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("kecck80:");
				break;
			case SKEIN:
				skein512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], 1); order++;
				TRACE("skein80:");
				break;
			case LUFFA:
				qubit_luffa512_cpu_hash_80_alexis(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("luffa80:");
				break;
			case CUBEHASH:
				cubehash512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("cube 80:");
				break;
			case SHAVITE:
				x11_shavite512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				TRACE("shavite:");
				break;
			case SIMD:
				x16_simd512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("simd512:");
				break;
			case ECHO:
//				x11_echo512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				x16_echo512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("echo   :");
				break;
			case HAMSI:
				x16_hamsi512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("hamsi  :");
				break;
			case FUGUE:
				x16_fugue512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("fugue  :");
				break;
			case SHABAL:
				x16_shabal512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("shabal :");
				break;
			case WHIRLPOOL:
				x16_whirlpool512_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("whirl  :");
				break;
			case SHA512:
				x16_sha512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				TRACE("sha512 :");
				break;
		}

		for (int i = 1; i < 16; i++)
		{
			const char elem = hashOrder[i];
			const uint8_t algo64 = elem >= 'A' ? elem - 'A' + 10 : elem - '0';

                        uint8_t nextalgo = -1;
                        if (i < 15)
                        {
                                const char elem2 = hashOrder[i + 1];
                                nextalgo = elem2 >= 'A' ? elem2 - 'A' + 10 : elem2 - '0';
                        }

			switch (algo64) {
			case BLAKE:
				quark_blake512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("blake  :");
				break;
			case BMW:
				quark_bmw512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("bmw    :");
				break;
			case GROESTL:
				quark_groestl512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("groestl:");
				break;
			case JH:
				quark_jh512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("jh512  :");
				break;
//			case KECCAK:
//				quark_keccak512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
                         case KECCAK:
                                quark_keccak512_cpu_hash_64(thr_id, throughput, NULL, d_hash[thr_id]); order++;
				TRACE("keccak :");
				break;
			case SKEIN:
				quark_skein512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("skein  :");
				break;
			case LUFFA:
				x11_luffa512_cpu_hash_64_alexis(thr_id, throughput, d_hash[thr_id]); order++;
				TRACE("luffa  :");
				break;
//			case CUBEHASH:
//				x11_cubehash512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
//				TRACE("cube   :");
//				break;
                                case CUBEHASH:
                                        if (nextalgo == SHAVITE)
                                        {
                                                x11_cubehash_shavite512_cpu_hash_64(thr_id, throughput, d_hash[thr_id]); order++;
                                                i = i + 1;
                                        }
                                        else
                                        {
                                                x11_cubehash512_cpu_hash_64(thr_id, throughput, d_hash[thr_id]); order++;
                                        }
                                break;
			case SHAVITE:
				x11_shavite512_cpu_hash_64_alexis(thr_id, throughput, d_hash[thr_id]); order++;
				TRACE("shavite:");
				break;
			case SIMD:
				x11_simd512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("simd   :");
				break;
			case ECHO:
				x11_echo512_cpu_hash_64_alexis(thr_id, throughput, d_hash[thr_id]); order++;
				TRACE("echo   :");
				break;
			case HAMSI:
				x13_hamsi512_cpu_hash_64_alexis(thr_id, throughput, d_hash[thr_id]); order++;
				TRACE("hamsi  :");
				break;
			case FUGUE:
				x13_fugue512_cpu_hash_64_alexis(thr_id, throughput, d_hash[thr_id]); order++;
				TRACE("fugue  :");
				break;
			case SHABAL:
				x14_shabal512_cpu_hash_64_alexis(thr_id, throughput, d_hash[thr_id]); order++;
				TRACE("shabal :");
				break;
			case WHIRLPOOL:
				x15_whirlpool_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				TRACE("shabal :");
				break;
//			case SHA512:
//				x17_sha512_cpu_hash_64(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
//				TRACE("sha512 :");
                        case SHA512:
                                x17_sha512_cpu_hash_64(thr_id, throughput, d_hash[thr_id]); order++;

				break;
			}
		}

		*hashes_done = pdata[19] - first_nonce + throughput;

		work->nonces[0] = cuda_check_hash(thr_id, throughput, pdata[19], d_hash[thr_id]);
#ifdef _DEBUG
		uint32_t _ALIGN(64) dhash[8];
		be32enc(&endiandata[19], pdata[19]);
		x16rt_hash(dhash, endiandata);
		applog_hash(dhash);
		return -1;
#endif
		if (work->nonces[0] != UINT32_MAX)
		{
			const uint32_t Htarg = ptarget[7];
			uint32_t _ALIGN(64) vhash[8];
			be32enc(&endiandata[19], work->nonces[0]);
			x16rt_hash(vhash, endiandata);

			if (vhash[7] < Htarg && fulltest(vhash, ptarget)) {
				work->valid_nonces = 1;
				work->nonces[1] = cuda_check_hash_suppl(thr_id, throughput, pdata[19], d_hash[thr_id], 1);
				work_set_target_ratio(work, vhash);
				if (work->nonces[1] != 0) {
					be32enc(&endiandata[19], work->nonces[1]);
					x16rt_hash(vhash, endiandata);
					bn_set_target_ratio(work, vhash, 1);
					work->valid_nonces++;
					pdata[19] = max(work->nonces[0], work->nonces[1]) + 1;
				} else {
					pdata[19] = work->nonces[0] + 1; // cursor
				}
				#ifdef GPU_HASH_CHECK_LOG
				gpulog(LOG_INFO, thr_id, "hash found with %s 80!", algo_strings[algo80]);

				algo80_tests[algo80] += work->valid_nonces;
				char oks64[128] = { 0 };
				char oks80[128] = { 0 };
				char fails[128] = { 0 };
				for (int a = 0; a < HASH_FUNC_COUNT; a++) {
						const char elem = hashOrder[a];
						const uint8_t algo64 = elem >= 'A' ? elem - 'A' + 10 : elem - '0';
						if (a > 0) algo64_tests[algo64] += work->valid_nonces;
						sprintf(&oks64[strlen(oks64)], "|%X:%2d", a, algo64_tests[a] < 100 ? algo64_tests[a] : 99);
						sprintf(&oks80[strlen(oks80)], "|%X:%2d", a, algo80_tests[a] < 100 ? algo80_tests[a] : 99);
						sprintf(&fails[strlen(fails)], "|%X:%2d", a, algo80_fails[a] < 100 ? algo80_fails[a] : 99);
				}
				applog(LOG_INFO, "K64: %s", oks64);
				applog(LOG_INFO, "K80: %s", oks80);
				applog(LOG_ERR,  "F80: %s", fails);
				#endif
				return work->valid_nonces;
			}
			else if (vhash[7] > Htarg) {
				// x11+ coins could do some random error, but not on retry
				gpu_increment_reject(thr_id);
				algo80_fails[algo80]++;
				if (!warn) {
					warn++;
					pdata[19] = work->nonces[0] + 1;
					continue;
				} else {
					if (!opt_quiet)	gpulog(LOG_WARNING, thr_id, "result for %08x does not validate on CPU! %s %s",
						work->nonces[0], algo_strings[algo80], hashOrder);
					warn = 0;
				}
			}
		}

		if ((uint64_t)throughput + pdata[19] >= max_nonce) {
			pdata[19] = max_nonce;
			break;
		}

		pdata[19] += throughput;

	} while (pdata[19] < max_nonce && !work_restart[thr_id].restart);

	*hashes_done = pdata[19] - first_nonce;
	return 0;
}

// cleanup
extern "C" void free_x16rt(int thr_id)
{
	if (!init[thr_id])
		return;

	cudaThreadSynchronize();

	cudaFree(d_hash[thr_id]);

	quark_blake512_cpu_free(thr_id);
	quark_groestl512_cpu_free(thr_id);
	x11_simd512_cpu_free(thr_id);
	x16_fugue512_cpu_free(thr_id); // to merge with x13_fugue512 ?
	x15_whirlpool_cpu_free(thr_id);

	cuda_check_cpu_free(thr_id);

	cudaDeviceSynchronize();
	init[thr_id] = false;
}
