FROM public.ecr.aws/lambda/python:3.9

# Install system dependencies including ffmpeg
RUN yum update -y && \
    yum install -y \
    wget \
    tar \
    xz \
    gzip \
    && yum clean all

# Install ffmpeg static binaries (more reliable than yum version)
RUN mkdir -p /opt/ffmpeg && \
    cd /opt/ffmpeg && \
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xf ffmpeg-release-amd64-static.tar.xz --strip-components=1 && \
    chmod +x ffmpeg ffprobe && \
    ln -s /opt/ffmpeg/ffmpeg /usr/local/bin/ffmpeg && \
    ln -s /opt/ffmpeg/ffprobe /usr/local/bin/ffprobe && \
    rm ffmpeg-release-amd64-static.tar.xz

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy function code
COPY stitch.py .

# Set the CMD to your handler
CMD ["stitch.lambda_handler"]