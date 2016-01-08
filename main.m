#import <Foundation/Foundation.h>

#include <stdlib.h> 
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <opencv/cv.h>
#include <opencv/cxcore.h>
#include <opencv/highgui.h>

#define BULB_PORT 56700
#define COLOR_DIV 64 



//------------------------------------------------------------------------------
#pragma pack(push, 1)
typedef struct {
	/* frame */
	uint16_t size;
	uint16_t protocol:12;
	uint8_t  addressable:1;
	uint8_t  tagged:1;
	uint8_t  origin:2;
	uint32_t source;
	/* frame address */
	uint8_t  target[8];
	uint8_t  reserved[6];
	uint8_t  res_required:1;
	uint8_t  ack_required:1;
	uint8_t  :6;
	uint8_t  sequence;
	/* protocol header */
	uint64_t :64;
	uint16_t type;
	uint16_t :16;
	/* variable length payload follows */
} lx_header_t;
#pragma pack(pop)

#pragma pack(push, 1)
typedef struct {
	uint8_t :8; 
	uint16_t hue;
	uint16_t saturation;
	uint16_t brightness;
	uint16_t kelvin;
	uint32_t duration;
} lx_payload_setcolor_t;
#pragma pack(pop)

#pragma pack(push, 1)
typedef struct {
	lx_header_t header;
	lx_payload_setcolor_t payload;
} lx_message_setcolor_t;
#pragma pack(pop)

//------------------------------------------------------------------------------
// Converts a CGImageRef to a CvMat.
CvMat* CvMatFromCGImageRef(CGImageRef image) 
{
	CGColorSpaceRef colorSpace;
	CGContextRef context;
	
	// use the generic RGB color space (??) 
	colorSpace = CGImageGetColorSpace(image);
    if (colorSpace == NULL)
    {
        fprintf(stderr, "error allocating color space\n");
        exit(1);
    }

	// get image width and height
    size_t cols = CGImageGetWidth(image);
    size_t rows = CGImageGetHeight(image);

	CvMat *result = cvCreateMat(rows, cols, CV_8UC4); 
	if (result == NULL) {
        fprintf(stderr, "memory not allocated\n");
        CGColorSpaceRelease(colorSpace);
		exit(1);
	}

    // create context
    context = CGBitmapContextCreate(result->data.ptr, 
									cols, rows,
									8,
 									result->step,
									colorSpace, 
									kCGBitmapByteOrder32Little | //BGRA
									kCGImageAlphaNoneSkipFirst);
	// release color space
    CGColorSpaceRelease(colorSpace);
	if (context == NULL) {
   		fprintf(stderr, "context not created\n");
		cvReleaseMat(&result);
        exit(1);
	}

	CGContextDrawImage(context, CGRectMake(0,0,cols,rows), image);
	CGContextRelease(context); 
    return result;
}

//------------------------------------------------------------------------------
void messageInit(lx_message_setcolor_t *message) 
{
	// set all values of the packet to zero
	memset((char*)message, 0, sizeof(lx_message_setcolor_t));

	lx_header_t *header = &(message->header);

	// frame
	header->size = sizeof(lx_message_setcolor_t);
	header->protocol = 1024;
	header->addressable = 1;
	header->tagged = 1;
	header->source = 0;
	// frame address
	header->res_required = 0;
	header->ack_required = 0;
	header->sequence = 0;
	// protocol 	
	header->type = 102;
	
}

//------------------------------------------------------------------------------
void messageSetColor(lx_message_setcolor_t *message, 
					  uint16_t hue, 
					  uint16_t saturation, 
					  uint16_t brightness,
					  uint16_t kelvin,
					  uint32_t duration) 
{

	lx_header_t *header = &(message->header);
	lx_payload_setcolor_t *payload = &(message->payload);

	// payload
	payload->hue = hue;
	payload->saturation = saturation;
	payload->brightness = brightness;
	payload->kelvin = kelvin; 
	payload->duration = duration;
}

//------------------------------------------------------------------------------
// Reduces number of colors from the input image. The number of colors 
// is 256/div and the minimum value for the single channel is div/2.
void colorReduce(CvMat *image, int div)
{
	const int size = image->rows * image->cols;
	for (int i=0; i<size; ++i) {
		// input matrix has 4 channels
		image->data.ptr[i * 4 + 0] = image->data.ptr[i * 4 + 0]/div*div+div/2;
		image->data.ptr[i * 4 + 1] = image->data.ptr[i * 4 + 1]/div*div+div/2;
		image->data.ptr[i * 4 + 2] = image->data.ptr[i * 4 + 2]/div*div+div/2;
	}
}


//------------------------------------------------------------------------------
CvMat *captureDisplay() 
{
	// capture an image of the main display (MacOSX)
	CGImageRef image = CGDisplayCreateImage(kCGDirectMainDisplay);
	
	// convert it to a CvMat
	CvMat *mat = CvMatFromCGImageRef(image);

	// release image
	CGImageRelease(image);

	// reduce number of colors
	colorReduce(mat, COLOR_DIV);

	return mat;
}

//------------------------------------------------------------------------------
void colorMessage(CvMat *image, lx_message_setcolor_t *message)
{
	const int size = image->rows * image->cols;

	CvMat *hls = cvCreateMat(image->rows, image->cols, CV_8UC3); 
	cvCvtColor(image, hls, CV_BGR2HLS);

	float hue=0, sat=0, bri=0; 

	for (int i = 0; i < size; ++i) {
		hue = hue * i/(i+1) + (float)hls->data.ptr[i * 3 + 0] / (i+1); 
		bri = bri * i/(i+1) + (float)hls->data.ptr[i * 3 + 1] / (i+1); 
		sat = sat * i/(i+1) + (float)hls->data.ptr[i * 3 + 2] / (i+1); 
	}
	

	cvReleaseMat(&hls);

	hue = (((int)hue*65535)/180)*2;
	sat = (((int)sat*65525)/255); 
	bri = (((int)bri*65535)/255);


	printf("%f, %f, %f\n", hue, sat, bri);


	messageSetColor(message, hue, sat, bri, 5000, 100);
}

//------------------------------------------------------------------------------
int main(int argc, char *argv[])
{
	struct sockaddr_in myaddr, remaddr;//cvShowImage("test", mat); 
	//cvWaitKey(0);

	int fd, slen=sizeof(remaddr);
	char *target = "192.168.0.255";

	// create a socket
	if ((fd=socket(AF_INET, SOCK_DGRAM, 0)) == -1) {
		fprintf(stderr, "socket() failed\n");
		exit(1);	
	}


	int broadcastEnable=1;
    int ret=setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, sizeof(broadcastEnable));

	
	memset((char*)&myaddr, 0, sizeof(myaddr)); 
	myaddr.sin_family = AF_INET;
	myaddr.sin_addr.s_addr = htonl(INADDR_ANY);
	myaddr.sin_port = htons(0);


	if (bind(fd, (struct sockaddr *)&myaddr, sizeof(myaddr)) < 0) {
		perror("bind failed");
		exit(1);
	}

	memset((char*)&remaddr, 0, sizeof(remaddr)); 
	remaddr.sin_family = AF_INET;
	remaddr.sin_port = htons(BULB_PORT);
	if (inet_aton(target, &(remaddr.sin_addr)) == 0) {
		fprintf(stderr, "inet_aton() failed\n");
		exit(1);
	}

	lx_message_setcolor_t message;
	messageInit(&message);

	// take a screenshot of the main display
	CvMat *mat = captureDisplay();
	colorMessage(mat, &message);
	cvReleaseMat(&mat);

	//cvShowImage("test", mat); 
	//cvWaitKey(0);

	// send message to lifx bulbs
	if (sendto(fd, &message, sizeof(message), 0, (struct sockaddr *)&remaddr, slen)==-1) {
			perror("sendto");
			exit(1);
	}


	return 0;
}







//------------------------------------------------------------------------------
/*void message_target(lx_header_t *header, uint8_t target[6])
{
	header->tagged = 0;
	header->addressable = 1;
	memcopy(header->target, target, sizeof(uint8_t)*6);
}*/



//------------------------------------------------------------------------------
/*CvMat* colorReduce(CvMat* image, int colorCount) {

	int size = image->rows * image->cols;

	CvMat *samples = cvCreateMat(size, 1, CV_32FC3);
	
	for (int i=0; i<size; ++i) {
		// input matrix has 4 channels
		samples->data.fl[i * 3 + 0] = image->data.ptr[i * 4 + 0];
		samples->data.fl[i * 3 + 1] = image->data.ptr[i * 4 + 1];
		samples->data.fl[i * 3 + 2] = image->data.ptr[i * 4 + 2];

		//printf("(%d,%d,%d)\n", image->data.ptr[i * 4 + 0], image->data.ptr[i * 4 + 1], image->data.ptr[i * 4 + 2]);

	}

	CvMat *labels = cvCreateMat(size, 1, CV_32SC1);

	// algorithm termination criteria
	const CvTermCriteria termcrit = cvTermCriteria(CV_TERMCRIT_EPS + CV_TERMCRIT_ITER, 10, 1.0);
  	cvKMeans2(samples, colorCount, labels, termcrit, 1, 0, 0, 0, 0);

	CvMat *colors = cvCreateMat(colorCount, 1, CV_32FC3);
	CvMat *count = cvCreateMat(colorCount, 1, CV_32SC1);

	// Find the average color for each label:
	// let the average of n numbers is x and the (n+1)th number is m, the
	// average of the n+1 numbers is: (n*x+m)/(n+1) = x*n/(n+1) + m/(n+1).
	for (int i=0; i<size; ++i) {
		int colorIndex = labels->data.i[i];
		int n = ++count->data.i[colorIndex];

		colors->data.fl[colorIndex * 3 + 0] = colors->data.fl[colorIndex * 3 + 0] * (n-1)/n + samples->data.fl[i * 3 + 0]/n; 		
		colors->data.fl[colorIndex * 3 + 1] = colors->data.fl[colorIndex * 3 + 1] * (n-1)/n + samples->data.fl[i * 3 + 1]/n; 		
		colors->data.fl[colorIndex * 3 + 2] = colors->data.fl[colorIndex * 3 + 2] * (n-1)/n + samples->data.fl[i * 3 + 2]/n; 		
	}

	CvMat *output = cvCreateMat(image->rows, image->cols, CV_8UC3);

    // Create the ouput matrix using the color matrix.
	for (int i=0; i<size; ++i) {
		int colorIndex = labels->data.i[i];
		output->data.ptr[i * 3 + 0] = colors->data.fl[colorIndex * 3 + 0];
		output->data.ptr[i * 3 + 1] = colors->data.fl[colorIndex * 3 + 1];
		output->data.ptr[i * 3 + 2] = colors->data.fl[colorIndex * 3 + 2];
	}

	cvReleaseMat(&samples);
	cvReleaseMat(&labels);
	cvReleaseMat(&colors);
	cvReleaseMat(&count);
	
	return output;
}*/

