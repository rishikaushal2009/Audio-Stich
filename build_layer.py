#!/usr/bin/env python3
"""
Cross-platform Lambda layer builder
Builds a minimized Lambda layer with only essential dependencies
"""

import os
import sys
import shutil
import subprocess
from pathlib import Path

def run_command(cmd):
    """Run command and return True if successful"""
    try:
        result = subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        print(f"OK: {cmd}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"FAILED: {cmd}")
        print(f"Error: {e.stderr}")
        return False

def clean_directory(path):
    """Remove directory if it exists and create fresh one"""
    path = Path(path)
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)
    print(f"Created clean directory: {path}")

def install_package(package, target_dir):
    """Install a package with all dependencies"""
    cmd = f"pip install --no-cache-dir {package} -t {target_dir}"
    return run_command(cmd)

def cleanup_unnecessary_files(layer_dir):
    """Remove unnecessary files to reduce layer size"""
    layer_path = Path(layer_dir)
    
    # Files and directories to remove
    patterns = [
        "*.pyc",
        "__pycache__",
        "*.dist-info",
        "tests",
        "test", 
        "*.egg-info",
        "examples",
        "docs",
        "*.md",
        "*.txt",
        "*.rst"
    ]
    
    removed_count = 0
    
    for pattern in patterns:
        if pattern.startswith("*."):
            # Handle file patterns
            for file_path in layer_path.rglob(pattern):
                try:
                    file_path.unlink()
                    removed_count += 1
                except Exception:
                    pass
        else:
            # Handle directory patterns
            for dir_path in layer_path.rglob(pattern):
                if dir_path.is_dir():
                    try:
                        shutil.rmtree(dir_path)
                        removed_count += 1
                    except Exception:
                        pass
    
    print(f"Cleaned up {removed_count} unnecessary files/directories")

def get_layer_size(layer_dir):
    """Calculate total size of layer directory"""
    total_size = 0
    for dirpath, dirnames, filenames in os.walk(layer_dir):
        for filename in filenames:
            filepath = os.path.join(dirpath, filename)
            try:
                total_size += os.path.getsize(filepath)
            except Exception:
                pass
    return total_size

def main():
    print("Building Lambda Layer")
    print("=" * 50)
    
    # Define paths - create in parent directory if we're in terraform/
    if Path.cwd().name == "terraform":
        layer_dir = Path("layer/python")
    else:
        layer_dir = Path("layer/python")
    
    # Clean and create directory
    clean_directory(layer_dir)
    
    # Essential packages with proper dependencies
    essential_packages = [
        "boto3",
        "pydub==0.25.1"
    ]
    
    print(f"\nInstalling {len(essential_packages)} essential packages...")
    failed_packages = []
    
    for package in essential_packages:
        if not install_package(package, layer_dir):
            failed_packages.append(package)
    
    if failed_packages:
        print(f"\nFailed to install: {failed_packages}")
        return False
    
    print(f"\nAll packages installed successfully")
    
    # Clean up unnecessary files
    print(f"\nCleaning up unnecessary files...")
    cleanup_unnecessary_files(layer_dir)
    
    # Check final size
    final_size = get_layer_size(layer_dir)
    size_mb = final_size / (1024 * 1024)
    
    print(f"\nFinal layer size: {size_mb:.1f} MB")
    
    if size_mb > 60:  # AWS Lambda layer limit is ~70MB, leave some buffer
        print(f"Warning: Layer size is close to AWS limit (70MB)")
    else:
        print(f"Layer size is within AWS limits")
    
    print(f"\nLambda layer built successfully!")
    print(f"Layer location: {layer_dir.absolute()}")
    
    return True

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
