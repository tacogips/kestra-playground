# Design References

This directory contains reference materials for system design and implementation.

## External References

| Name | URL | Description |
|------|-----|-------------|
| Python Documentation | https://docs.python.org/3/ | Official Python language and standard library documentation |
| Python Packaging User Guide | https://packaging.python.org/ | Python packaging standards and project configuration guidance |
| uv Documentation | https://docs.astral.sh/uv/ | uv package and project management documentation |
| Ruff Documentation | https://docs.astral.sh/ruff/ | Python linting and formatting documentation |
| ty Documentation | https://docs.astral.sh/ty/ | Python type checker documentation |
| Kestra Docker Compose | https://kestra.io/docs/installation/docker-compose | Official Kestra Docker Compose setup with PostgreSQL and multi-component examples |
| Kestra Configuration | https://kestra.io/docs/configuration | Official Kestra runtime configuration entry point |
| Kestra Kubernetes | https://kestra.io/docs/installation/kubernetes | Official Kestra Helm/Kubernetes deployment and scaling guidance |
| Kestra GCP GKE | https://kestra.io/docs/installation/kubernetes-gcp-gke | Official GKE, Cloud SQL, and GCS deployment guidance |
| Apple container command reference | https://github.com/apple/container/blob/main/docs/command-reference.md | Apple container CLI command, network, and volume reference |
| pytest Documentation | https://docs.pytest.org/ | Python testing framework documentation |

## Reference Documents

Reference documents should be organized by topic:

```
references/
├── README.md              # This index file
├── python/                # Python patterns and practices
└── <topic>/               # Other topic-specific references
```

## Adding References

When adding new reference materials:

1. Create a topic directory if it does not exist
2. Add reference documents with clear naming
3. Update this README.md with the reference entry
