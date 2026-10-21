// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
/* Quantized Conv2d graph used to validate real HTP execution. */

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

#ifndef HEIGHT
#define HEIGHT 32U
#endif
#ifndef WIDTH
#define WIDTH 32U
#endif
#ifndef IN_CHANNELS
#define IN_CHANNELS 32U
#endif
#ifndef OUT_CHANNELS
#define OUT_CHANNELS 128U
#endif
#ifndef KERNEL
#define KERNEL 3U
#endif
#define OUT_HEIGHT (HEIGHT - KERNEL + 1U)
#define OUT_WIDTH (WIDTH - KERNEL + 1U)
#define INPUT_SIZE (HEIGHT * WIDTH * IN_CHANNELS)
#define WEIGHT_SIZE (KERNEL * KERNEL * IN_CHANNELS * OUT_CHANNELS)
#define OUTPUT_SIZE (OUT_HEIGHT * OUT_WIDTH * OUT_CHANNELS)

typedef Qnn_ErrorHandle_t (*get_providers_fn)(const QnnInterface_t ***providers,
                                              uint32_t *count);

static void qnn_log(const char *format, QnnLog_Level_t level,
                    uint64_t timestamp, va_list arguments) {
  (void)timestamp;
  fprintf(stderr, "qnn[%d]: ", (int)level);
  vfprintf(stderr, format, arguments);
  fputc('\n', stderr);
}

static int report_error(const char *operation, Qnn_ErrorHandle_t error) {
  if (!error)
    return 0;
  fprintf(stderr, "%s failed: %#" PRIx64 "\n", operation, (uint64_t)error);
  return -1;
}

static void init_tensor(Qnn_Tensor_t *tensor, const char *name,
                        Qnn_TensorType_t type, uint32_t *dimensions) {
  *tensor = (Qnn_Tensor_t)QNN_TENSOR_INIT;
  tensor->v1.name = name;
  tensor->v1.type = type;
  tensor->v1.dataFormat = QNN_TENSOR_DATA_FORMAT_FLAT_BUFFER;
  tensor->v1.dataType = QNN_DATATYPE_UFIXED_POINT_8;
  tensor->v1.quantizeParams.encodingDefinition = QNN_DEFINITION_DEFINED;
  tensor->v1.quantizeParams.quantizationEncoding =
      QNN_QUANTIZATION_ENCODING_SCALE_OFFSET;
  tensor->v1.quantizeParams.scaleOffsetEncoding.scale = 1.0f;
  tensor->v1.quantizeParams.scaleOffsetEncoding.offset = 0;
  tensor->v1.rank = 4;
  tensor->v1.dimensions = dimensions;
  tensor->v1.memType = QNN_TENSORMEMTYPE_RAW;
}

int main(int argc, char **argv) {
  const char *backend_path = argc > 1 ? argv[1] : "libQnnHtp.so";
  const QnnInterface_t **providers = NULL;
  const QNN_INTERFACE_VER_TYPE *qnn = NULL;
  Qnn_BackendHandle_t backend = NULL;
  Qnn_ContextHandle_t context = NULL;
  Qnn_DeviceHandle_t device = NULL;
  Qnn_GraphHandle_t graph = NULL;
  Qnn_LogHandle_t logger = NULL;
  Qnn_Tensor_t tensors[6];
  Qnn_Tensor_t node_inputs[2];
  Qnn_Tensor_t node_outputs[1];
  Qnn_Param_t parameters[3] = {QNN_PARAM_INIT, QNN_PARAM_INIT, QNN_PARAM_INIT};
  Qnn_Tensor_t exec_inputs[1];
  Qnn_Tensor_t exec_outputs[1];
  Qnn_OpConfig_t operation = QNN_OPCONFIG_INIT;
  uint32_t input_dims[] = {1, HEIGHT, WIDTH, IN_CHANNELS};
  uint32_t weight_dims[] = {KERNEL, KERNEL, IN_CHANNELS, OUT_CHANNELS};
  uint32_t output_dims[] = {1, OUT_HEIGHT, OUT_WIDTH, OUT_CHANNELS};
  uint32_t vector_dims[] = {2}, pad_dims[] = {2, 2};
  uint32_t stride[] = {1, 1}, dilation[] = {1, 1};
  uint32_t padding[] = {0, 0, 0, 0};
  uint8_t *input_a = NULL;
  uint8_t *input_b = NULL;
  uint8_t *output = NULL;
  get_providers_fn get_providers;
  const char *build_id = NULL;
  void *backend_library = NULL;
  uint32_t provider_count = 0;
  uint32_t i, y, x, channel, ky, kx, inner;
  uint32_t max_error = 0;
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
             providers[i]->providerName ? providers[i]->providerName
                                        : "unnamed",
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
                   qnn->logCreate(qnn_log, QNN_LOG_LEVEL_WARN, &logger)))
    goto done;
  if (report_error("QnnBackend_create",
                   qnn->backendCreate(logger, NULL, &backend)))
    goto done;
  if (qnn->backendGetBuildId && !qnn->backendGetBuildId(&build_id) && build_id)
    printf("QNN backend build: %s\n", build_id);
  if (qnn->deviceCreate &&
      report_error("QnnDevice_create",
                   qnn->deviceCreate(logger, NULL, &device)))
    goto done;
  if (report_error("QnnContext_create",
                   qnn->contextCreate(backend, device, NULL, &context)))
    goto done;
  if (report_error("QnnGraph_create",
                   qnn->graphCreate(context, "caihong_htp_conv", NULL, &graph)))
    goto done;
  input_a = calloc(INPUT_SIZE, 1);
  input_b = calloc(WEIGHT_SIZE, 1);
  output = calloc(OUTPUT_SIZE, 1);
  if (!input_a || !input_b || !output) {
    fprintf(stderr, "cannot allocate tensors\n");
    goto done;
  }
  for (i = 0; i < INPUT_SIZE; i++)
    input_a[i] =
        (uint8_t)(128U +
                  (((i * 0x9e3779b1U ^ (i >> 4) * 0x85ebca6bU) >> 31) &
                   1U));
  for (i = 0; i < WEIGHT_SIZE; i++)
    input_b[i] =
        (uint8_t)(128U +
                  ((((i + 17U) * 0x85ebca6bU ^
                     (i >> 3) * 0xc2b2ae35U) >>
                    31) &
                   1U));

  init_tensor(&tensors[0], "input", QNN_TENSOR_TYPE_APP_WRITE, input_dims);
  tensors[0].v1.quantizeParams.scaleOffsetEncoding.offset = -128;
  init_tensor(&tensors[1], "weights", QNN_TENSOR_TYPE_STATIC, weight_dims);
  tensors[1].v1.quantizeParams.scaleOffsetEncoding.offset = -128;
  tensors[1].v1.clientBuf.data = input_b;
  tensors[1].v1.clientBuf.dataSize = WEIGHT_SIZE;
  init_tensor(&tensors[2], "output", QNN_TENSOR_TYPE_APP_READ, output_dims);
  tensors[2].v1.quantizeParams.scaleOffsetEncoding.offset = -128;
  init_tensor(&tensors[3], "stride", QNN_TENSOR_TYPE_STATIC, vector_dims);
  init_tensor(&tensors[4], "dilation", QNN_TENSOR_TYPE_STATIC, vector_dims);
  init_tensor(&tensors[5], "padding", QNN_TENSOR_TYPE_STATIC, pad_dims);
  for (i = 3; i < 6; i++) {
    tensors[i].v1.dataType = QNN_DATATYPE_UINT_32;
    tensors[i].v1.quantizeParams =
        (Qnn_QuantizeParams_t)QNN_QUANTIZE_PARAMS_INIT;
    tensors[i].v1.rank = i == 5 ? 2 : 1;
    tensors[i].v1.clientBuf.data = i == 3   ? (void *)stride
                                   : i == 4 ? (void *)dilation
                                            : (void *)padding;
    tensors[i].v1.clientBuf.dataSize =
        i == 5 ? sizeof(padding) : sizeof(stride);
  }
  for (i = 0; i < 6; i++)
    if (report_error("QnnTensor_createGraphTensor",
                     qnn->tensorCreateGraphTensor(graph, &tensors[i])))
      goto done;
  parameters[0].paramType = QNN_PARAMTYPE_TENSOR;
  parameters[0].name = QNN_OP_CONV_2D_PARAM_STRIDE;
  parameters[0].tensorParam = tensors[3];
  parameters[1].paramType = QNN_PARAMTYPE_TENSOR;
  parameters[1].name = QNN_OP_CONV_2D_PARAM_DILATION;
  parameters[1].tensorParam = tensors[4];
  parameters[2].paramType = QNN_PARAMTYPE_TENSOR;
  parameters[2].name = QNN_OP_CONV_2D_PARAM_PAD_AMOUNT;
  parameters[2].tensorParam = tensors[5];

  node_inputs[0] = tensors[0];
  node_inputs[1] = tensors[1];
  node_outputs[0] = tensors[2];
  operation.v1.name = "conv";
  operation.v1.packageName = QNN_OP_PACKAGE_NAME_QTI_AISW;
  operation.v1.typeName = QNN_OP_CONV_2D;
  operation.v1.numOfParams = 3;
  operation.v1.params = parameters;
  operation.v1.numOfInputs = 2;
  operation.v1.inputTensors = node_inputs;
  operation.v1.numOfOutputs = 1;
  operation.v1.outputTensors = node_outputs;
  if (report_error("QnnGraph_addNode", qnn->graphAddNode(graph, operation)))
    goto done;
  if (report_error("QnnGraph_finalize", qnn->graphFinalize(graph, NULL, NULL)))
    goto done;

  exec_inputs[0] = tensors[0];
  exec_outputs[0] = tensors[2];
  exec_inputs[0].v1.clientBuf.data = input_a;
  exec_inputs[0].v1.clientBuf.dataSize = INPUT_SIZE;
  exec_outputs[0].v1.clientBuf.data = output;
  exec_outputs[0].v1.clientBuf.dataSize = OUTPUT_SIZE;
  if (report_error("QnnGraph_execute",
                   qnn->graphExecute(graph, exec_inputs, 1, exec_outputs, 1,
                                     NULL, NULL)))
    goto done;
  for (y = 0; y < OUT_HEIGHT; y++) {
    for (x = 0; x < OUT_WIDTH; x++) {
      for (channel = 0; channel < OUT_CHANNELS; channel++) {
        uint32_t expected = 0, error;
        for (ky = 0; ky < KERNEL; ky++)
          for (kx = 0; kx < KERNEL; kx++)
            for (inner = 0; inner < IN_CHANNELS; inner++)
              expected +=
                  (input_a[((y + ky) * WIDTH + x + kx) * IN_CHANNELS + inner] -
                   128U) *
                  (input_b[((ky * KERNEL + kx) * IN_CHANNELS + inner) *
                               OUT_CHANNELS +
                           channel] -
                   128U);
        i = (y * OUT_WIDTH + x) * OUT_CHANNELS + channel;
        expected += 128U;
        error =
            output[i] > expected ? output[i] - expected : expected - output[i];
        if (error > max_error)
          max_error = error;
        if (error > 1) {
          fprintf(stderr, "Conv2d mismatch [%u,%u,%u]: got=%u expected=%u\n", y,
                  x, channel, output[i], expected);
          goto done;
        }
      }
    }
  }
  printf("QNN HTP Conv2d PASS: %ux%ux%u -> %ux%ux%u, max_error=%u\n", HEIGHT,
         WIDTH, IN_CHANNELS, OUT_HEIGHT, OUT_WIDTH, OUT_CHANNELS, max_error);
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
