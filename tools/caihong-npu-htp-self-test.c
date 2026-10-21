// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
/* Execute a small QNN graph on the Qualcomm HTP backend and verify its result. */

#include <dlfcn.h>
#include <inttypes.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "QnnInterface.h"
#include "QnnOpDef.h"

#define TEST_ELEMENTS 1024U

typedef Qnn_ErrorHandle_t (*get_providers_fn)(
	const QnnInterface_t ***providers, uint32_t *count);

static void qnn_log(const char *format, QnnLog_Level_t level,
		    uint64_t timestamp, va_list arguments)
{
	(void)timestamp;
	fprintf(stderr, "qnn[%d]: ", (int)level);
	vfprintf(stderr, format, arguments);
	fputc('\n', stderr);
}

static int report_error(const char *operation, Qnn_ErrorHandle_t error)
{
	if (!error)
		return 0;
	fprintf(stderr, "%s failed: %#" PRIx64 "\n", operation,
		(uint64_t)error);
	return -1;
}

static void init_tensor(Qnn_Tensor_t *tensor, const char *name,
			Qnn_TensorType_t type, uint32_t *dimensions)
{
	*tensor = (Qnn_Tensor_t)QNN_TENSOR_INIT;
	tensor->v1.name = name;
	tensor->v1.type = type;
	tensor->v1.dataFormat = QNN_TENSOR_DATA_FORMAT_FLAT_BUFFER;
	tensor->v1.dataType = QNN_DATATYPE_FLOAT_32;
	tensor->v1.rank = 1;
	tensor->v1.dimensions = dimensions;
	tensor->v1.memType = QNN_TENSORMEMTYPE_RAW;
}

int main(int argc, char **argv)
{
	const char *backend_path = argc > 1 ? argv[1] : "libQnnHtp.so";
	const QnnInterface_t **providers = NULL;
	const QNN_INTERFACE_VER_TYPE *qnn = NULL;
	Qnn_BackendHandle_t backend = NULL;
	Qnn_ContextHandle_t context = NULL;
	Qnn_DeviceHandle_t device = NULL;
	Qnn_GraphHandle_t graph = NULL;
	Qnn_LogHandle_t logger = NULL;
	Qnn_Tensor_t tensors[3];
	Qnn_Tensor_t node_inputs[2];
	Qnn_Tensor_t node_outputs[1];
	Qnn_Tensor_t exec_inputs[2];
	Qnn_Tensor_t exec_outputs[1];
	Qnn_OpConfig_t operation = QNN_OPCONFIG_INIT;
	uint32_t dimensions[] = { TEST_ELEMENTS };
	float *input_a = NULL;
	float *input_b = NULL;
	float *output = NULL;
	get_providers_fn get_providers;
	const char *build_id = NULL;
	void *backend_library = NULL;
	uint32_t provider_count = 0;
	uint32_t i;
	float max_error = 0.0f;
	int status = 1;

	backend_library = dlopen(backend_path, RTLD_NOW | RTLD_LOCAL);
	if (!backend_library) {
		fprintf(stderr, "cannot load %s: %s\n", backend_path, dlerror());
		goto done;
	}
	*(void **)(&get_providers) =
		dlsym(backend_library, "QnnInterface_getProviders");
	if (!get_providers) {
		fprintf(stderr, "QnnInterface_getProviders is unavailable: %s\n",
			dlerror());
		goto done;
	}
	if (report_error("QnnInterface_getProviders",
			 get_providers(&providers, &provider_count)))
		goto done;
	for (i = 0; i < provider_count; i++) {
		if (providers[i]->apiVersion.coreApiVersion.major ==
				QNN_API_VERSION_MAJOR &&
		    providers[i]->apiVersion.coreApiVersion.minor >=
				QNN_API_VERSION_MINOR) {
			qnn = &providers[i]->QNN_INTERFACE_VER_NAME;
			printf("QNN provider: %s, API %u.%u.%u\n",
			       providers[i]->providerName ? providers[i]->providerName :
						      "unnamed",
			       providers[i]->apiVersion.coreApiVersion.major,
			       providers[i]->apiVersion.coreApiVersion.minor,
			       providers[i]->apiVersion.coreApiVersion.patch);
			break;
		}
	}
	if (!qnn) {
		fprintf(stderr, "no compatible QNN provider found\n");
		goto done;
	}
	if (!qnn->backendCreate || !qnn->contextCreate || !qnn->graphCreate ||
	    !qnn->tensorCreateGraphTensor || !qnn->graphAddNode ||
	    !qnn->graphFinalize || !qnn->graphExecute) {
		fprintf(stderr, "QNN provider lacks a required graph API\n");
		goto done;
	}
	if (qnn->logCreate &&
	    report_error("QnnLog_create",
			 qnn->logCreate(qnn_log, QNN_LOG_LEVEL_ERROR, &logger)))
		goto done;
	if (report_error("QnnBackend_create",
			 qnn->backendCreate(logger, NULL, &backend)))
		goto done;
	if (qnn->backendGetBuildId &&
	    !qnn->backendGetBuildId(&build_id) && build_id)
		printf("QNN backend build: %s\n", build_id);
	if (qnn->deviceCreate &&
	    report_error("QnnDevice_create",
			 qnn->deviceCreate(logger, NULL, &device)))
		goto done;
	if (report_error("QnnContext_create",
			 qnn->contextCreate(backend, device, NULL, &context)))
		goto done;
	if (report_error("QnnGraph_create",
			 qnn->graphCreate(context, "caihong_htp_add", NULL,
					  &graph)))
		goto done;

	init_tensor(&tensors[0], "input_a", QNN_TENSOR_TYPE_APP_WRITE,
		    dimensions);
	init_tensor(&tensors[1], "input_b", QNN_TENSOR_TYPE_APP_WRITE,
		    dimensions);
	init_tensor(&tensors[2], "output", QNN_TENSOR_TYPE_APP_READ,
		    dimensions);
	for (i = 0; i < 3; i++)
		if (report_error("QnnTensor_createGraphTensor",
				 qnn->tensorCreateGraphTensor(graph, &tensors[i])))
			goto done;

	node_inputs[0] = tensors[0];
	node_inputs[1] = tensors[1];
	node_outputs[0] = tensors[2];
	operation.v1.name = "add";
	operation.v1.packageName = QNN_OP_PACKAGE_NAME_QTI_AISW;
	operation.v1.typeName = QNN_OP_ELEMENT_WISE_ADD;
	operation.v1.numOfInputs = 2;
	operation.v1.inputTensors = node_inputs;
	operation.v1.numOfOutputs = 1;
	operation.v1.outputTensors = node_outputs;
	if (report_error("QnnGraph_addNode", qnn->graphAddNode(graph, operation)))
		goto done;
	if (report_error("QnnGraph_finalize",
			 qnn->graphFinalize(graph, NULL, NULL)))
		goto done;

	if (posix_memalign((void **)&input_a, 64,
			   TEST_ELEMENTS * sizeof(*input_a)) ||
	    posix_memalign((void **)&input_b, 64,
			   TEST_ELEMENTS * sizeof(*input_b)) ||
	    posix_memalign((void **)&output, 64,
			   TEST_ELEMENTS * sizeof(*output))) {
		fprintf(stderr, "cannot allocate aligned tensors\n");
		goto done;
	}
	for (i = 0; i < TEST_ELEMENTS; i++) {
		input_a[i] = (float)i * 0.25f;
		input_b[i] = (float)(TEST_ELEMENTS - i) * 0.5f;
		output[i] = 0.0f;
	}
	exec_inputs[0] = tensors[0];
	exec_inputs[1] = tensors[1];
	exec_outputs[0] = tensors[2];
	exec_inputs[0].v1.clientBuf.data = input_a;
	exec_inputs[0].v1.clientBuf.dataSize =
		TEST_ELEMENTS * sizeof(*input_a);
	exec_inputs[1].v1.clientBuf.data = input_b;
	exec_inputs[1].v1.clientBuf.dataSize =
		TEST_ELEMENTS * sizeof(*input_b);
	exec_outputs[0].v1.clientBuf.data = output;
	exec_outputs[0].v1.clientBuf.dataSize =
		TEST_ELEMENTS * sizeof(*output);
	if (report_error("QnnGraph_execute",
			 qnn->graphExecute(graph, exec_inputs, 2, exec_outputs, 1,
					   NULL, NULL)))
		goto done;
	for (i = 0; i < TEST_ELEMENTS; i++) {
		float expected = input_a[i] + input_b[i];

		float error = fabsf(output[i] - expected);
		float tolerance = 0.01f + fabsf(expected) * 0.0001f;

		if (error > max_error)
			max_error = error;
		if (error > tolerance) {
			fprintf(stderr,
				"output mismatch at %u: got=%a expected=%a error=%g\n",
				i, output[i], expected, error);
			goto done;
		}
	}
	printf("QNN HTP PASS: ElementWiseAdd float32 elements=%u max_error=%g\n",
	       TEST_ELEMENTS, max_error);
	status = 0;

done:
	free(output);
	free(input_b);
	free(input_a);
	if (context && qnn && qnn->contextFree)
		qnn->contextFree(context, NULL);
	if (device && qnn && qnn->deviceFree)
		qnn->deviceFree(device);
	if (backend && qnn && qnn->backendFree)
		qnn->backendFree(backend);
	if (logger && qnn && qnn->logFree)
		qnn->logFree(logger);
	if (backend_library)
		dlclose(backend_library);
	return status;
}
