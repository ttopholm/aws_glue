# AWS Glue 4 with VS Code Server Support

Multi-architecture Docker image based on AWS Glue 4.0.0 libraries with VS Code Server remote development support for both AMD64 and ARM64 platforms.

## Features

- **Multi-Architecture Support**: Native builds for `linux/amd64` and `linux/arm64`
- **AWS Glue 4.0.0**: Based on `amazon/aws-glue-libs:glue_libs_4.0.0_image_01`
- **VS Code Remote Development**: Full support for VS Code Server with custom glibc 2.28 sysroot
- **UV Package Manager**: Fast Python package management with Astral's UV
- **Custom Toolchain**: Built-in cross-compilation toolchain using crosstool-NG
- **Spark Development**: Pre-configured Spark environment for local Glue development

## Quick Start

### Pull the Image

```bash
# Latest build
docker pull ghcr.io/<username>/aws_glue:4-latest

# Specific date
docker pull ghcr.io/<username>/aws_glue:4-20241002
```

### Run the Container

```bash
docker run -d \
  --name aws-glue-dev \
  -p 8888:8888 \
  -p 4040:4040 \
  -v $(pwd):/workspace \
  ghcr.io/<username>/aws_glue:4-latest
```

### Connect with VS Code

1. Install the **Remote - Containers** extension in VS Code
2. Click the green icon in the bottom-left corner
3. Select **Attach to Running Container**
4. Choose the `aws-glue-dev` container

The container automatically configures the custom glibc sysroot for VS Code Server compatibility.

## Available Tags

- `4-latest` - Most recent build
- `4-YYYYMMDD` - Date-specific builds (e.g., `4-20241002`)
- `4-1.0.0` - Semantic versioned releases
- `4-pr-*` - Pull request builds for testing

## Building Locally

### Prerequisites

- Docker with BuildKit enabled
- Docker Buildx plugin

### Build for Your Architecture

```bash
docker build -t aws_glue:4-local .
```

### Build Multi-Architecture

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t aws_glue:4-local \
  --load \
  .
```

## Architecture

This image is built in multiple stages:

1. **patchelf-builder**: Builds static `patchelf` binary for runtime patching
2. **sysroot-builder**: Creates glibc 2.28 sysroot using crosstool-NG
3. **uv-source**: Fetches UV package manager binary
4. **final**: Combines everything into AWS Glue base image

### Key Components

- **Base Image**: Amazon Linux 2 with AWS Glue 4.0.0 libraries
- **Python**: 3.10 (AWS Glue standard)
- **glibc**: 2.28 (custom sysroot for VS Code compatibility)
- **GCC**: 10.5.0 (toolchain)
- **Spark**: Pre-configured for local development

## Environment Variables

### VS Code Server Configuration

```bash
VSCODE_SERVER_PATCHELF_PATH=/usr/local/bin/patchelf
VSCODE_SERVER_CUSTOM_GLIBC_LINKER=/opt/sysroot/glibc-2.28/lib/ld-2.28.so
VSCODE_SERVER_CUSTOM_GLIBC_PATH=/opt/sysroot/glibc-2.28/lib:...
```

### UV Configuration

```bash
UV_LINK_MODE=copy
UV_COMPILE_BYTECODE=1
UV_PYTHON_DOWNLOADS=never
UV_PYTHON=python3.10
```

## Usage Examples

### Developing Glue Jobs

```python
# example_job.py
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)

# Your Glue job code here
df = spark.read.csv("/workspace/data/input.csv")
df.show()
```

### Installing Dependencies with UV

```bash
# Inside the container
uv pip install pandas numpy boto3
```

### Running Spark Jobs

```bash
spark-submit \
  --master local[*] \
  /workspace/example_job.py
```

## Development Workflow

1. **Start Container**: Launch the container with your workspace mounted
2. **Connect VS Code**: Attach VS Code to the running container
3. **Develop**: Write and test Glue jobs locally
4. **Deploy**: Upload tested jobs to AWS Glue

## Troubleshooting

### VS Code Server Won't Start

Ensure the sysroot paths are correctly set:

```bash
ls -la $VSCODE_SERVER_CUSTOM_GLIBC_LINKER
ls -la /opt/sysroot/glibc-2.28/
```

### Permission Issues

The container runs as `glue_user` with sudo access. If you encounter permission issues:

```bash
sudo chown -R glue_user:glue_user /workspace
```

### Spark UI Not Accessible

Ensure port 4040 is exposed and mapped:

```bash
docker run -p 4040:4040 ...
```

## CI/CD

This project includes GitHub Actions workflow for automated multi-architecture builds:

- Builds on push to `main` or `develop`
- Automatic tagging with date and version
- Caching for faster subsequent builds
- Publishes to GitHub Container Registry

See `.github/workflows/docker-build.yml` for details.

## Build Arguments

Customize the build with these arguments:

```bash
docker build \
  --build-arg GLUE_VERSION=4.0.0 \
  --build-arg GLIBC_VERSION=2.28 \
  --build-arg GCC_VERSION=10.5.0 \
  --build-arg UV_VERSION=latest \
  -t aws_glue:4-custom \
  .
```

## License

This project is based on AWS Glue libraries. Please refer to AWS licensing terms for the base image.

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## Support

For issues and questions:

- **AWS Glue Documentation**: https://docs.aws.amazon.com/glue/
- **GitHub Issues**: Open an issue in this repository
- **VS Code Remote Development**: https://code.visualstudio.com/docs/remote/containers

## Acknowledgments

- AWS Glue team for the base libraries
- Microsoft for VS Code and crosstool-NG configurations
- Astral for the UV package manager
- NixOS for patchelf