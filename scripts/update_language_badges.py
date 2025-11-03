#!/usr/bin/env python3
"""
Automatically detect languages in submodules and update README badges.

This script:
1. Analyzes all submodules for programming languages
2. Calculates accurate percentages
3. Updates README.md with dynamic language badges
4. Maintains the badges automatically
"""

import os
import subprocess
import re
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Tuple


class LanguageAnalyzer:
    """Analyzes programming languages across submodules."""
    
    def __init__(self):
        self.repo_root = Path(__file__).parent.parent
        self.language_map = {
            '.py': 'Python',
            '.js': 'JavaScript', 
            '.ts': 'TypeScript',
            '.proto': 'Protocol Buffer',
            '.go': 'Go',
            '.rs': 'Rust',
            '.java': 'Java',
            '.cpp': 'C++',
            '.c': 'C',
            '.h': 'C/C++ Header',
            '.hpp': 'C++ Header',
            '.sh': 'Shell',
            '.bash': 'Bash',
            '.zsh': 'Zsh',
            '.yaml': 'YAML',
            '.yml': 'YAML',
            '.json': 'JSON',
            '.toml': 'TOML',
            '.dockerfile': 'Dockerfile',
            '.sql': 'SQL',
            '.html': 'HTML',
            '.css': 'CSS',
            '.scss': 'SCSS',
            '.rb': 'Ruby',
            '.php': 'PHP',
            '.kt': 'Kotlin',
            '.swift': 'Swift',
            '.dart': 'Dart',
            '.r': 'R',
            '.scala': 'Scala',
            '.clj': 'Clojure',
            '.hs': 'Haskell',
            '.elm': 'Elm',
            '.lua': 'Lua',
            '.perl': 'Perl',
            '.pl': 'Perl'
        }
        
        # Language colors for badges (from GitHub's language colors)
        self.language_colors = {
            'Python': '3776AB',
            'JavaScript': 'F7DF1E',
            'TypeScript': '3178C6',
            'Protocol Buffer': '4285F4',
            'Go': '00ADD8',
            'Rust': 'DEA584',
            'Java': 'ED8B00',
            'C++': '00599C',
            'C': '555555',
            'Shell': '89e051',
            'YAML': 'cb171e',
            'JSON': '292929',
            'TOML': '9c4221',
            'Dockerfile': '384d54',
            'HTML': 'e34c26',
            'CSS': '1572B6',
            'Ruby': '701516',
            'PHP': '777BB4'
        }
    
    def get_submodules(self) -> List[str]:
        """Get list of all submodules."""
        try:
            result = subprocess.run(
                ["git", "submodule", "status"],
                capture_output=True,
                text=True,
                check=True,
                cwd=self.repo_root
            )
            
            submodules = []
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        submodules.append(parts[1])
            
            return submodules
        except subprocess.CalledProcessError:
            return []
    
    def analyze_directory(self, directory: Path) -> Dict[str, int]:
        """Analyze languages in a directory by counting lines of code."""
        language_lines = defaultdict(int)
        
        for root, dirs, files in os.walk(directory):
            # Skip hidden directories and common ignore patterns
            dirs[:] = [d for d in dirs if not d.startswith('.') and d not in [
                'node_modules', '__pycache__', 'target', 'build', 'dist', 
                '.git', '.vscode', '.idea', 'venv', 'env'
            ]]
            
            for file in files:
                if file.startswith('.'):
                    continue
                
                file_path = Path(root) / file
                extension = file_path.suffix.lower()
                
                # Special cases for files without extensions
                if file.lower() in ['dockerfile', 'makefile']:
                    extension = f'.{file.lower()}'
                
                if extension in self.language_map:
                    language = self.language_map[extension]
                    
                    try:
                        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                            lines = len([line for line in f if line.strip()])
                            language_lines[language] += lines
                    except (UnicodeDecodeError, PermissionError, IsADirectoryError):
                        # Skip binary files or files we can't read
                        pass
        
        return dict(language_lines)
    
    def analyze_submodules(self) -> Dict[str, Dict[str, int]]:
        """Analyze languages across all submodules."""
        submodules = self.get_submodules()
        results = {}
        
        print("🔍 Analyzing languages in submodules...")
        
        for submodule in submodules:
            submodule_path = self.repo_root / submodule
            
            if not submodule_path.exists():
                print(f"⚠️  Submodule {submodule} not found")
                continue
            
            print(f"📁 Analyzing {submodule}...")
            language_lines = self.analyze_directory(submodule_path)
            
            if language_lines:
                results[submodule] = language_lines
                total_lines = sum(language_lines.values())
                print(f"   Found {len(language_lines)} languages, {total_lines} lines")
            else:
                print(f"   No recognized languages found")
        
        return results
    
    def calculate_percentages(self, language_lines: Dict[str, int]) -> List[Tuple[str, float]]:
        """Calculate language percentages and return sorted by percentage."""
        total_lines = sum(language_lines.values())
        if total_lines == 0:
            return []
        
        percentages = [
            (lang, (lines / total_lines) * 100)
            for lang, lines in language_lines.items()
        ]
        
        # Sort by percentage (descending) and only include languages > 1%
        return sorted(
            [(lang, pct) for lang, pct in percentages if pct >= 1.0],
            key=lambda x: x[1],
            reverse=True
        )
    
    def create_language_badge(self, language: str, percentage: float) -> str:
        """Create a language badge with percentage."""
        color = self.language_colors.get(language, '666666')
        pct_str = f"{percentage:.1f}%25"  # URL encode the % symbol
        
        return f"![{language}](https://img.shields.io/badge/{language}-{pct_str}-{color}?style=flat-square)"
    
    def generate_service_table(self, analysis_results: Dict[str, Dict[str, int]]) -> str:
        """Generate the technology stack table with language badges."""
        
        # Service descriptions
        descriptions = {
            'container-maker-spec': 'gRPC service definitions and generated code',
            'socket-ssh': 'WebSocket server for SSH connections',
            'cert-manager': 'Certificate management service',
            'browseterm-server': 'Main application server and API gateway',
            'payment-service': 'Payment processing and billing service',
            'postgres-ha': 'High-availability PostgreSQL cluster',
            'redis-cluster': 'Redis cluster for caching and sessions'
        }
        
        table_lines = [
            "## 🛠️ Technology Stack",
            "",
            "| Service | Primary Languages | Description |",
            "|---------|------------------|-------------|"
        ]
        
        for service, language_lines in analysis_results.items():
            percentages = self.calculate_percentages(language_lines)
            
            # Create badges for top languages (max 3)
            badges = []
            for lang, pct in percentages[:3]:
                badge = self.create_language_badge(lang, pct)
                badges.append(badge)
            
            badges_str = " ".join(badges) if badges else "No languages detected"
            description = descriptions.get(service, f"{service.replace('-', ' ').title()} service")
            
            table_lines.append(f"| **{service}** | {badges_str} | {description} |")
        
        return "\n".join(table_lines)
    
    def update_readme(self, analysis_results: Dict[str, Dict[str, int]]) -> None:
        """Update README.md with new language analysis."""
        readme_path = self.repo_root / "README.md"
        
        if not readme_path.exists():
            print("❌ README.md not found")
            return
        
        # Read current README
        with open(readme_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Generate new technology stack table
        new_table = self.generate_service_table(analysis_results)
        
        # Find where to insert/replace the technology stack section
        # Look for existing technology stack section
        tech_stack_pattern = r'## 🛠️ Technology Stack.*?(?=\n## |\n# |$)'
        
        if re.search(tech_stack_pattern, content, re.DOTALL):
            # Replace existing section
            content = re.sub(tech_stack_pattern, new_table, content, flags=re.DOTALL)
        else:
            # Insert after the main description, before service list
            insert_pattern = r'(This repository holds the complete browseterm project\..*?\n\n)'
            replacement = r'\1' + new_table + '\n\n'
            content = re.sub(insert_pattern, replacement, content, flags=re.DOTALL)
        
        # Write updated README
        with open(readme_path, 'w', encoding='utf-8') as f:
            f.write(content)
        
        print(f"✅ Updated {readme_path}")
    
    def run(self) -> None:
        """Run the complete language analysis and README update."""
        print("🚀 Starting language analysis...")
        
        analysis_results = self.analyze_submodules()
        
        if not analysis_results:
            print("❌ No submodules found or analyzed")
            return
        
        print(f"\n📊 Analysis Summary:")
        print("=" * 50)
        
        total_services = len(analysis_results)
        total_languages = set()
        total_lines = 0
        
        for service, language_lines in analysis_results.items():
            service_total = sum(language_lines.values())
            total_lines += service_total
            total_languages.update(language_lines.keys())
            
            percentages = self.calculate_percentages(language_lines)
            top_lang = percentages[0] if percentages else ("Unknown", 0)
            
            print(f"{service:20} {top_lang[0]:15} ({top_lang[1]:.1f}%) - {service_total:,} lines")
        
        print(f"\nTotal: {total_services} services, {len(total_languages)} languages, {total_lines:,} lines")
        
        # Update README
        self.update_readme(analysis_results)
        
        print("\n✅ Language analysis complete!")
        print("💡 Tip: Run this script regularly to keep language badges up-to-date")


def main():
    """Main entry point."""
    analyzer = LanguageAnalyzer()
    analyzer.run()


if __name__ == "__main__":
    main()
