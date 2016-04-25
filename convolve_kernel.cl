__kernel void convolve(
                       __global const float * in,
                       __global float * merge,
                       __global const float * weights,
                       __private int filter_size,
                       __local float * channel_buff,
                       __local float * filter_buff) {

    // cl::NDRange global(channels, outputs);
    const unsigned int c = get_global_id(0);  // channel
    const unsigned int o = get_global_id(1);  // output

    const unsigned int channels = get_global_size(0);
    const unsigned int outputs = get_global_size(1);

    // cl::NDRange local(2, (1->32));
    const unsigned int lx = get_local_id(0);
    const unsigned int ly = get_local_id(1);

    const unsigned int chan_buff_size = get_local_size(0);
    const unsigned int out_buff_size  = get_local_size(1);

    const unsigned int filter_len = filter_size * filter_size;
    const unsigned int mid = (filter_size / 2) + 1;
    const unsigned int extent = mid - 1;

    // input = channels * height * width
    // output = outputs * height * width
    // weights = output * channels * filter
    // merge = channels * outputs * height * width

    // Copy the filter we are applying locally
    // output * channel * filter_len
    for (unsigned int f = 0; f < filter_len; f++) {
        filter_buff[(ly * chan_buff_size + lx) * filter_len + f]
            = weights[(o * channels + c) * filter_len + f];
    }
    __local const float * filter_offset =
        &filter_buff[(ly * chan_buff_size + lx) * filter_len];

    const unsigned int width = 19;
    const unsigned int height = 19;
    const unsigned int board_size = width * height;

    // Copy the input channels locally
    for (unsigned int b = 0; b < board_size; b++) {
        channel_buff[lx * board_size + b] = in[(c * board_size) + b];
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    for (unsigned int ch = 0; ch < height; ch++) {
        int fhstart = ch - extent;
        int fhend   = ch + extent;
        for (unsigned int cw = 0; cw < width; cw++) {
            int fwstart = cw - extent;
            int fwend   = cw + extent;
            unsigned int filter_idx = 0;
            float out = 0.0f;
            // Start filter
            for (int fh = fhstart; fh <= fhend; fh++) {
                for (int fw = fwstart; fw <= fwend; fw++) {
                    // "zero padding"
                    if ((unsigned)fh >= height) {
                        filter_idx++;
                        continue;
                    }
                    if ((unsigned)fw >= width) {
                        filter_idx++;
                        continue;
                    }

                    float input = channel_buff[(lx * height + fh) * width + fw];
                    out += input * filter_offset[filter_idx];

                    filter_idx++;
                }
            }
            // End filter
            merge[((c * outputs + o) * height + ch) * width + cw] = out;
        }
    }
}

__kernel void merge(
                    __global const float * in,
                    __global float * out,
                    __constant const float * biases,
                    __private const int channels) {

    // cl::NDRange global(outputs);
    const int gx = get_global_id(0);
    const int gy = get_global_id(1);

    const int output = gx;
    const int b = gy;
    const int outputs = get_global_size(0);

    const int width = 19;
    const int height = 19;
    const int boardsize = width * height;

    const int o = output;
    const float bias = biases[o];

    float sum = bias;
    for (unsigned int c = 0; c < channels; c++) {
        sum += in[(c * outputs + o) * boardsize + b];
    }
    // ReLU if outputs > 1 (not last layer)
    if (outputs > 1) {
        sum = (sum > 0.0f) ? sum : 0.0f;
    }
    out[o * boardsize + b] = sum;
}

__kernel void batchnorm(
			__global const float * in,
			__global float * out,
			__constant const float * means,
			__constant const float * variances,
			__constant const float * scale) {

    // cl::NDRange global(outputs, 19*19);
    const int gx = get_global_id(0);
    const int gy = get_global_id(1);

    const int output = gx;
    const int outputs = get_global_size(0);

    const unsigned int width = 19;
    const unsigned int height = 19;
    const unsigned int board_size = width * height;

    const unsigned int c = output;
    const unsigned int b = gy;

    const float mean = means[c] / scale[0];
    const float variance = variances[c] / scale[0];
    const float scale_stddiv = 1.0f / sqrt(variance);

    out[c * board_size + b] = scale_stddiv * (in[c * board_size + b] - mean);
}